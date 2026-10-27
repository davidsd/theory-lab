"""Offline submission tests: fake SSH accepts one held job and returns metadata."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'hpc/hpc-submit'


class SubmissionMetadataTests(unittest.TestCase):
    def run_case(self, metadata, lookup_status=0, command='sbatch test.sh'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'state').mkdir()
            (root / 'lib.sh').write_text('''
LAB=$SUBMIT_TEST_ROOT
HPC_AUTO_SUS_PER_JOB=1000
HPC_AUTO_SUS_PER_DAY=10000
HPC_LAB_SUS_PER_MONTH=100000
HPC_WHOLE_NODE_PARTITIONS=batch,test
HPC_CORES_PER_NODE=64
project_field() { echo 100000; }
now() { date -Iseconds; }
die() { echo "$*" >&2; exit 1; }
''')
            ssh = root / 'ssh'
            ssh.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
command = sys.argv[-1]
with open(Path(os.environ['SUBMIT_TEST_ROOT'], 'ssh.log'), 'a') as log:
    log.write(command + '\\n')
if 'sbatch --hold ' in command:
    print('Submitted batch job 12345')
elif command == 'scontrol show job -o 12345':
    print(os.environ['SUBMIT_TEST_METADATA'])
    sys.exit(int(os.environ['SUBMIT_TEST_LOOKUP_STATUS']))
elif command == 'scontrol release 12345':
    Path(os.environ['SUBMIT_TEST_ROOT'], 'released').touch()
else:
    sys.exit(99)
''')
            ssh.chmod(0o755)
            env = dict(os.environ, AGENTBOX_SHARE=str(root), SUBMIT_TEST_ROOT=str(root),
                       SUBMIT_TEST_METADATA=metadata, SUBMIT_TEST_LOOKUP_STATUS=str(lookup_status),
                       PATH=f'{root}:{os.environ["PATH"]}')
            result = subprocess.run(['bash', str(SCRIPT), '--project', 'test', '--issue', '1',
                                     '--reason', 'offline test', '--', command],
                                    env=env, capture_output=True, text=True)
            ledger = root / 'state/hpc-ledger.tsv'
            self.ssh_log = (root / 'ssh.log').read_text() if (root / 'ssh.log').exists() else ''
            return result, (root / 'released').exists(), ledger.read_text() if ledger.exists() else ''

    def test_bad_metadata_stays_held(self):
        cases = [('', 0), ('', 1),
                 ('Partition=test NumNodes=1 NumCPUs=64', 0),
                 ('Partition=test NumNodes=oops NumCPUs=64 TimeLimit=00:30:00', 0),
                 ('Partition=test NumNodes=1 NumCPUs=64 TimeLimit=bad', 0),
                 ('Partition=test NumNodes=1 NumCPUs=64 TimeLimit=00:00:00', 0),
                 ('Partition=test NumNodes=0 NumCPUs=64 TimeLimit=00:30:00', 0)]
        for metadata, status in cases:
            with self.subTest(metadata=metadata, status=status):
                result, released, ledger = self.run_case(metadata, status)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(released)
                self.assertEqual(ledger, '')
                self.assertIn('12345 remains held', result.stderr)

    def test_valid_costs_keep_existing_rounding(self):
        for partition, cpus, limit, expected in [('test', 64, '00:30:00', '64'),
                                                ('shared', 4, '01:30:00', '8')]:
            with self.subTest(partition=partition):
                result, released, ledger = self.run_case(
                    f'Partition={partition} NumNodes=1 NumCPUs={cpus} TimeLimit={limit}')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(released)
                self.assertEqual(ledger.split('\t')[9], expected)


    def test_hold_goes_on_the_parsed_sbatch(self):
        # a folder name containing "sbatch " must not take the --hold
        result, released, _ = self.run_case('Partition=test NumNodes=1 NumCPUs=64 TimeLimit=00:30:00',
                                            command='cd "a sbatch b" && sbatch test.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.ssh_log.splitlines()[0], 'cd "a sbatch b" && sbatch --hold test.sh')

    def test_wrap_may_not_submit_jobs(self):
        result, released, ledger = self.run_case('Partition=test NumNodes=1 NumCPUs=64 TimeLimit=00:30:00',
                                                 command="sbatch -p test --wrap 'sbatch big.sh'")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('may not call sbatch', result.stderr)
        self.assertEqual(self.ssh_log, '')
        self.assertFalse(released)
        self.assertEqual(ledger, '')


    def test_no_process_substitution_or_redirects(self):
        for command in ['sbatch <(sbatch big.sh)', 'sbatch test.sh > out', 'sbatch < test.sh']:
            result, released, ledger = self.run_case('Partition=test NumNodes=1 NumCPUs=64 TimeLimit=00:30:00',
                                                     command=command)
            self.assertNotEqual(result.returncode, 0, command)
            self.assertEqual(self.ssh_log, '', command)
            self.assertFalse(released, command)


if __name__ == '__main__':
    unittest.main()
