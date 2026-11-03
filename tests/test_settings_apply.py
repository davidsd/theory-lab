"""Offline tests of settings/lab-settings-apply's decision logic (no GitHub, no root, no lab.conf)."""
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "settings/lab-settings-apply"
_loader = importlib.machinery.SourceFileLoader("lab_settings_apply", str(SCRIPT))
apply = importlib.util.module_from_spec(importlib.util.spec_from_loader("lab_settings_apply", _loader))
_loader.exec_module(apply)

PI, BOT = "the-pi", "lab-bot"
MAXIMA = {"HPC_AUTO_SUS_PER_DAY": 30000, "AGENT_POOL_CPUS_MAX": 8}


def comment(n, login, body, edited=False):
    t = f"2026-01-01T00:{n:02d}:00Z"
    return {"created_at": t, "updated_at": "2026-01-01T01:00:00Z" if edited else t, "body": body,
            "user": {"login": login}, "html_url": f"https://example.invalid/c{n}"}


def proposal(n, pid, key, frm, to, login=BOT, edited=False):
    return comment(n, login, f"**P{pid}: why**\n\n`{key}`: {frm or '(unset)'} → **{to}** (hard maximum 1).\n"
                             f"<!-- lab-setting P{pid} KEY={key} FROM={frm} TO={to} -->", edited)


def decide(comments, conf=None, done=None, pi=PI):
    done = {} if done is None else done
    return apply.decide(comments, pi, done, MAXIMA, conf or {"HPC_AUTO_SUS_PER_DAY": "10000"}), done


class DecideTests(unittest.TestCase):
    def test_pi_approval_applies(self):
        out, done = decide([proposal(1, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "20000"), comment(2, PI, "approve P1")])
        self.assertEqual(out, [("1", "HPC_AUTO_SUS_PER_DAY", "10000", "20000", "applied", "https://example.invalid/c2")])
        self.assertEqual(done, {"1": "applied"})

    def test_bare_approve_takes_the_one_open_proposal(self):
        out, _ = decide([proposal(1, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "20000"), comment(2, PI, "Approve.")])
        self.assertEqual(out[0][4], "applied")

    def test_bare_approve_with_two_open_does_nothing(self):
        out, _ = decide([proposal(1, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "20000"),
                         proposal(2, 2, "AGENT_POOL_CPUS_MAX", "", "6"), comment(3, PI, "approve")])
        self.assertEqual(out, [])

    def test_only_the_pi_approves(self):
        for who in (BOT, "someone-else"):
            out, _ = decide([proposal(1, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "20000"), comment(2, who, "approve P1")])
            self.assertEqual(out, [], who)

    def test_no_pi_configured_approves_nothing(self):
        out, _ = decide([proposal(1, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "20000"), comment(2, "", "approve P1")], pi="")
        self.assertEqual(out, [])

    def test_approval_before_the_proposal_does_not_count(self):
        out, _ = decide([comment(1, PI, "approve P1"), proposal(2, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "20000")])
        self.assertEqual(out, [])

    def test_key_not_listed_is_refused(self):
        out, _ = decide([proposal(1, 1, "NTFY_URL", "", "1"), comment(2, PI, "approve P1")])
        self.assertTrue(out[0][4].startswith("refused: NTFY_URL is not a key"))

    def test_above_hard_maximum_is_refused(self):
        out, _ = decide([proposal(1, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "30001"), comment(2, PI, "approve P1")])
        self.assertIn("above the hard maximum 30000", out[0][4])

    def test_stale_from_is_refused(self):
        out, _ = decide([proposal(1, 1, "HPC_AUTO_SUS_PER_DAY", "5000", "20000"), comment(2, PI, "approve P1")])
        self.assertIn("lab.conf has HPC_AUTO_SUS_PER_DAY=10000, not 5000", out[0][4])

    def test_unset_key_matches_empty_from(self):
        out, _ = decide([proposal(1, 1, "AGENT_POOL_CPUS_MAX", "", "6"), comment(2, PI, "approve P1")])
        self.assertEqual(out[0][4], "applied")

    def test_edited_proposal_is_refused(self):
        out, done = decide([proposal(1, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "20000", edited=True),
                            comment(2, PI, "approve P1")])
        self.assertEqual([o[4][:31] for o in out], ["refused: the proposal was edite"])   # reported once, not applied
        self.assertTrue(done["1"].startswith("refused: the proposal was edited"))

    def test_hidden_marker_must_match_visible_text(self):
        c = comment(1, BOT, "**P1: why**\n\n`HPC_AUTO_SUS_PER_DAY`: 10000 → **12000**\n"
                            "<!-- lab-setting P1 KEY=HPC_AUTO_SUS_PER_DAY FROM=10000 TO=29000 -->")
        out, done = decide([c, comment(2, PI, "approve P1")])
        self.assertEqual([o[4] for o in out], [done["1"]])
        self.assertIn("visible text", done["1"])

    def test_visible_text_inside_an_html_comment_does_not_count(self):
        c = comment(1, BOT, "**P1: why** <!-- `HPC_AUTO_SUS_PER_DAY`: 10000 → **29000** -->\n"
                            "<!-- lab-setting P1 KEY=HPC_AUTO_SUS_PER_DAY FROM=10000 TO=29000 -->")
        out, _ = decide([c, comment(2, PI, "approve P1")])
        self.assertIn("visible text", out[0][4])

    def test_set_conf_changes_every_line_of_the_key(self):
        import tempfile, os
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "lab.conf")
            open(p, "w").write("A=1   # first\nB=2\nA=3\n")
            saved, apply.CONF = apply.CONF, p
            try:
                apply.set_conf("A", "7")
                self.assertEqual(open(p).read(), "A=7   # first\nB=2\nA=7\n")
                self.assertEqual(apply.conf_values()["A"], "7")
            finally:
                apply.CONF = saved

    def test_first_claim_of_a_number_wins(self):
        out, _ = decide([proposal(1, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "20000"),
                         proposal(2, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "29000"), comment(3, PI, "approve P1")])
        self.assertEqual(out[0][3], "20000")

    def test_cancel(self):
        out, _ = decide([proposal(1, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "20000"), comment(2, PI, "cancel P1")])
        self.assertEqual(out[0][4], "cancelled")

    def test_decided_once(self):
        done = {"1": "applied"}
        out, _ = decide([proposal(1, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "20000"), comment(2, PI, "approve P1")], done=done)
        self.assertEqual(out, [])

    def test_two_changes_to_one_key_in_one_run(self):
        # The second proposal's FROM is the first one's TO: it applies only after the first.
        out, _ = decide([proposal(1, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "20000"), comment(2, PI, "approve P1"),
                         proposal(3, 2, "HPC_AUTO_SUS_PER_DAY", "20000", "25000"), comment(4, PI, "approve P2")])
        self.assertEqual([o[4] for o in out], ["applied", "applied"])

    def test_approval_text_must_be_the_whole_comment(self):
        out, _ = decide([proposal(1, 1, "HPC_AUTO_SUS_PER_DAY", "10000", "20000"),
                         comment(2, PI, "I don't approve P1 yet")])
        self.assertEqual(out, [])


if __name__ == "__main__":
    unittest.main()
