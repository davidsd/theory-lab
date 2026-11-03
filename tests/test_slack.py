"""Offline tests of the Slack tools' checks: slack.conf parsing, which posts are allowed (DMs to the PI,
summaries with --attach/--then, mentions), and how the listener reads the PI's answer to a summary offer.
No Slack, no network, no slack_sdk: the listener's imports are stubbed."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest

KIT = Path(__file__).resolve().parents[1]


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))
    loader.exec_module(mod)
    return mod


# The listener imports slack_sdk at the top; stand-ins are enough for its pure functions.
for name in ("slack_sdk", "slack_sdk.socket_mode", "slack_sdk.socket_mode.response", "slack_sdk.web"):
    sys.modules.setdefault(name, types.ModuleType(name))
sys.modules["slack_sdk.socket_mode"].SocketModeClient = object
sys.modules["slack_sdk.socket_mode.response"].SocketModeResponse = object
sys.modules["slack_sdk.web"].WebClient = object
os.environ["LAB_SLACK"] = str(KIT / "slack/lab-slack")
listen = load("lab_slack_listen", KIT / "slack/lab-slack-listen")
ls = listen.ls   # the listener's own copy of lab-slack, so both see the paths patched below

CONF = """
workspace ws
pi ws UPI0000001
channel ws proj-a projects=pa mode=post posters=lead
channel ws proj-b projects=pb mode=draft posters=lead,worker
channel ws readonly projects=pa mode=read
person ws UCOLLAB001 octocat
"""


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.saved = (ls.CONF, ls.STATE, ls.APPROVED, ls.SUMMARY_OFFERS)
        ls.CONF = root / "slack.conf"
        ls.CONF.write_text(CONF)
        ls.STATE = root / "state"
        ls.STATE.mkdir()
        ls.APPROVED = ls.STATE / "approved"
        ls.SUMMARY_OFFERS = ls.STATE / "summary-offers.json"
        ls.PI_SLACK.clear()

    def tearDown(self):
        ls.CONF, ls.STATE, ls.APPROVED, ls.SUMMARY_OFFERS = self.saved
        self.tmp.cleanup()


class ConfTests(Tmp):
    def test_pi_line_makes_a_dm_pseudo_channel(self):
        ws, chans, people = ls.parse_conf()
        dm = ls.find_channel(chans, "ws/@pi")
        self.assertEqual(dm["dm"], "UPI0000001")
        self.assertEqual(ls.PI_SLACK, {"ws": "UPI0000001"})
        self.assertEqual(people, {("ws", "UCOLLAB001"): "octocat"})

    def test_no_pi_line_no_dm(self):
        ls.CONF.write_text(CONF.replace("pi ws UPI0000001\n", ""))
        _, chans, _ = ls.parse_conf()
        self.assertFalse(any(c.get("dm") for c in chans))

    def test_person_line_needs_a_user_id(self):
        ls.CONF.write_text(CONF + "person ws SomeDisplayName someone\n")
        with self.assertRaises(SystemExit):
            ls.parse_conf()


class RequestTests(Tmp):
    def check(self, **req):
        _, chans, _ = ls.parse_conf()
        base = dict(project="pa", role="lead", channel="ws/proj-a", text="hello")
        base.update(req)
        return ls.check_request(base, chans)[1]

    def test_ordinary_post(self):
        self.assertIsNone(self.check())

    def test_wrong_project_role_or_mode(self):
        self.assertIn("isn't allowed", self.check(project="pb"))
        self.assertIn("may not post", self.check(role="worker"))
        self.assertIn("read-only", self.check(channel="ws/readonly"))

    def test_mentions_refused(self):
        for text in ("hi <!channel>", "hi @here", "hi <!subteam^S123>"):
            self.assertIsNotNone(self.check(text=text), text)

    def test_director_may_dm_the_pi(self):
        self.assertIsNone(self.check(project="lab", role="director", channel="ws/@pi"))

    def test_lead_dms_the_pi_only_a_summary(self):
        self.assertIn("only the director", self.check(channel="ws/@pi"))
        self.assertIn("only the director", self.check(channel="ws/@pi", attach=True))
        self.assertIsNone(self.check(channel="ws/@pi", attach=True, issue="https://example.invalid/1"))

    def test_then_only_with_a_dm_and_a_channel_of_the_project(self):
        self.assertIn("only for posts to", self.check(then="ws/proj-a"))
        ok = dict(channel="ws/@pi", attach=True, issue="https://example.invalid/1")
        self.assertIsNone(self.check(then="ws/proj-a", **ok))
        self.assertIn("isn't a channel", self.check(then="ws/proj-b", **ok))      # another project's
        self.assertIn("isn't a channel", self.check(then="ws/readonly", **ok))    # read-only
        self.assertIn("isn't a channel", self.check(then="ws/@pi", **ok))         # the DM itself

    def test_approved_post_rechecks_the_channel(self):
        _, chans, _ = ls.parse_conf()
        req = dict(project="pa", role="lead", channel="ws/proj-a", text="x")
        self.assertIsNone(ls.check_request(req, chans, approved=True)[1])
        req["project"] = "pb"
        self.assertIn("no longer takes posts", ls.check_request(req, chans, approved=True)[1])

    def test_draft_hash_covers_channel_thread_and_text(self):
        a = dict(channel="ws/proj-b", thread=None, text="x")
        self.assertEqual(ls.draft_hash(a), ls.draft_hash(dict(a)))
        for k, v in (("channel", "ws/proj-a"), ("thread", "1.2"), ("text", "y")):
            self.assertNotEqual(ls.draft_hash(a), ls.draft_hash(dict(a, **{k: v})), k)


class SummaryTests(Tmp):
    def offer(self, ts, status="open", thread="100.1", name="2026-01-30-am.pdf", t=1.0, then="ws/proj-a"):
        offers = ls.read_json(ls.SUMMARY_OFFERS, {})
        offers[ts] = dict(time=t, dm="D1", project="pa", role="lead", then=then, issue="https://example.invalid/5",
                          text="abstract", attach=dict(name=name, path=str(ls.STATE / name), copy=name, sha256="0"),
                          status=status, thread=thread)
        ls.write_atomic(ls.SUMMARY_OFFERS, json.dumps(offers))
        return offers

    def test_revision_goes_to_the_thread_of_the_same_half_day(self):
        self.offer("200.1", thread="100.1", name="2026-01-30-am.pdf")
        self.assertEqual(ls.summary_thread("pa", "https://example.invalid/5", "summaries/2026-01-30-am-v2.pdf"), "100.1")
        self.assertIsNone(ls.summary_thread("pa", "https://example.invalid/5", "summaries/2026-01-30-pm.pdf"))
        self.assertIsNone(ls.summary_thread("pa", "https://example.invalid/6", "summaries/2026-01-30-am-v2.pdf"))

    def test_decided_offers_take_no_revisions(self):
        self.offer("200.1", status="approved")
        self.assertIsNone(ls.summary_thread("pa", "https://example.invalid/5", "summaries/2026-01-30-am-v2.pdf"))

    def test_the_newest_open_offer_in_a_thread_answers(self):
        self.offer("200.1", t=1.0, status="superseded")   # as lab-slack's offer() marks an older version
        offers = self.offer("300.1", t=2.0)
        self.assertEqual(listen.summary_offer(offers, "100.1")["time"], 2.0)   # a reply under the PDF
        self.assertEqual(listen.summary_offer(offers, "300.1")["time"], 2.0)   # or under the newest prompt
        self.assertIsNone(listen.summary_offer(offers, "200.1"))               # not the superseded one
        self.assertIsNone(listen.summary_offer(offers, "999.9"))

    def test_post_answers_queue_the_approved_post(self):
        for text in ("post", "Post it", "yes, post it", "ok post to #proj-a", "share", "approve"):
            o = self.offer("200.1")["200.1"]
            reply = listen.summary_answer(o, text, "100.1")
            self.assertEqual(o["status"], "approved", text)
            self.assertIn("#proj-a", reply)
        queued = [json.loads(p.read_text()) for p in ls.APPROVED.glob("*.json")]
        self.assertTrue(queued and all(q["channel"] == "ws/proj-a" for q in queued))

    def test_post_to_another_channel_is_a_comment_not_an_approval(self):
        o = self.offer("200.1")["200.1"]
        calls = []
        listen.subprocess.run, saved = (lambda *a, **k: calls.append(a) or types.SimpleNamespace(returncode=0)), listen.subprocess.run
        try:
            listen.summary_answer(o, "post to #proj-b", "100.1")
        finally:
            listen.subprocess.run = saved
        self.assertEqual(o["status"], "comments")
        self.assertFalse(ls.APPROVED.exists() and list(ls.APPROVED.glob("*.json")))

    def test_no_drops_it(self):
        o = self.offer("200.1")["200.1"]
        listen.summary_answer(o, "no", "100.1")
        self.assertEqual(o["status"], "dropped")

    def test_without_a_channel_post_is_refused(self):
        o = self.offer("200.1", then=None)["200.1"]
        reply = listen.summary_answer(o, "post", "100.1")
        self.assertEqual(o["status"], "open")
        self.assertIn("no Slack channel", reply)

    def test_other_text_is_relayed_as_the_pis_comments(self):
        o = self.offer("200.1")["200.1"]
        calls = []
        listen.subprocess.run, saved = (lambda *a, **k: calls.append(a[0]) or types.SimpleNamespace(returncode=0)), listen.subprocess.run
        try:
            listen.summary_answer(o, "Please define the cutoff in section 2.", "100.1")
        finally:
            listen.subprocess.run = saved
        self.assertEqual(o["status"], "comments")
        self.assertEqual(calls[0][:4], ["gh", "issue", "comment", "https://example.invalid/5"])
        self.assertIn("From the PI (via Slack, relayed by the lab)", calls[0][5])


if __name__ == "__main__":
    unittest.main()
