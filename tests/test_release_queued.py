"""Offline tests of hpc/hpc-release-queued's limit check (no cluster, no GitHub)."""
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "hpc/hpc-release-queued"
_loader = importlib.machinery.SourceFileLoader("hpc_release_queued", str(SCRIPT))
rq = importlib.util.module_from_spec(importlib.util.spec_from_loader("hpc_release_queued", _loader))
_loader.exec_module(rq)

NOW, MONTH0 = 1_800_000_000, 1_800_000_000 - 10 * 86400
CONF = {"HPC_AUTO_SUS_PER_JOB": 2000, "HPC_AUTO_SUS_PER_DAY": 10000, "HPC_LAB_SUS_PER_MONTH": 50000}


def row(t, project, job, sus, status):
    # epoch, time, project, issue, job, partition, nodes, CPUs, hours, SUs, status, reason, URL
    return [str(t), "-", project, "1", job, "shared", "1", "8", "1", str(sus), status, "r", "https://example.invalid/i"]


class FitsTests(unittest.TestCase):
    def fits(self, rows, queued, budgets=None, standing=None):
        return rq.fits(queued, rows, CONF, budgets or {}, standing or {}, NOW, MONTH0)

    def test_fits_when_the_day_has_room(self):
        q = row(NOW - 60, "p", "9", 1500, "held")
        rows = [row(NOW - 3600, "p", "1", 8000, "auto"), q]
        self.assertTrue(self.fits(rows, q))

    def test_waits_while_the_day_is_full(self):
        q = row(NOW - 60, "p", "9", 1500, "held")
        rows = [row(NOW - 3600, "p", "1", 9000, "auto"), q]
        self.assertFalse(self.fits(rows, q))

    def test_old_releases_leave_the_window(self):
        q = row(NOW - 60, "p", "9", 1500, "held")
        rows = [row(NOW - 90000, "p", "1", 9000, "auto"), q]
        self.assertTrue(self.fits(rows, q))

    def test_held_and_cancelled_jobs_do_not_count(self):
        q = row(NOW - 60, "p", "9", 1500, "held")
        rows = [row(NOW - 3600, "p", "1", 9000, "held"), row(NOW - 3600, "p", "2", 9000, "cancelled"), q]
        self.assertTrue(self.fits(rows, q))

    def test_per_job_limit_always_applies(self):
        q = row(NOW - 60, "p", "9", 2001, "held")
        self.assertFalse(self.fits([q], q, standing={"p": {"until": NOW + 3600}}))

    def test_monthly_budget(self):
        q = row(NOW - 60, "p", "9", 1500, "held")
        rows = [row(MONTH0 + 10, "p", str(i), 2000, "approved") for i in range(25)] + [q]   # 50000 this month
        self.assertFalse(self.fits(rows, q, standing={"p": {"until": NOW + 3600}}))

    def test_project_budget(self):
        q = row(NOW - 60, "p", "9", 1500, "held")
        rows = [row(MONTH0 + 10, "p", "1", 1000, "auto"), q]
        self.assertFalse(self.fits(rows, q, budgets={"p": 2000}))
        self.assertTrue(self.fits(rows, q, budgets={"p": 2500}))
        self.assertTrue(self.fits(rows, q, budgets={"other": 100}))

    def test_standing_approval_skips_only_the_daily_limit(self):
        q = row(NOW - 60, "p", "9", 1500, "held")
        rows = [row(NOW - 3600, "p", "1", 9000, "auto"), q]
        self.assertTrue(self.fits(rows, q, standing={"p": {"until": NOW + 3600, "why": "test"}}))
        self.assertFalse(self.fits(rows, q, standing={"p": {"until": NOW - 1}}))           # expired
        self.assertFalse(self.fits(rows, q, standing={"other": {"until": NOW + 3600}}))    # another project's
        self.assertFalse(self.fits(rows, q, standing={"p": {"until": "soon"}}))            # malformed


if __name__ == "__main__":
    unittest.main()
