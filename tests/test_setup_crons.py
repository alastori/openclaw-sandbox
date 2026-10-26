"""Run cron setup against an isolated fake CLI, never the gateway."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
NAMES = [
    "nightly-update-check", "nightly-security-audit", "morning-log-review",
    "nightly-doc-drift", "weekly-memory-synthesis", "weekly-doc-watch",
    "nightly-auth-health", "cascade-detect",
]
FAKE_OC = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

path = Path(os.environ['FAKE_OC_STATE'])
state = json.loads(path.read_text())
args = sys.argv[1:]
state.setdefault('calls', []).append(args)
path.write_text(json.dumps(state))
action = args[1]
if state.get('fail_action') == action:
    sys.exit(1)
if action == 'list':
    if sum(c[1] == 'list' for c in state['calls']) > state.get('fail_list_after', float('inf')):
        sys.exit(1)
    if 'listing' in state:
        print(state['listing'])
    else:
        print(state.get('prefix', '') + json.dumps({'jobs': state['jobs'], 'total': len(state['jobs']), 'hasMore': False}))
    sys.exit(0)
if action == 'add':
    job = {'id': 'added-' + str(len(state['jobs'])), 'enabled': True}
    state['jobs'].append(job)
else:
    job = next(j for j in state['jobs'] if j['id'] == args[2])
if action == 'disable':
    job['enabled'] = False
elif action in ('edit', 'add'):
    job['name'] = args[args.index('--name') + 1]
    job['argv'] = json.loads(args[args.index('--command-argv') + 1])
else:
    sys.exit('Unexpected mutation: ' + action)
path.write_text(json.dumps(state))
"""


def job(name, suffix="", enabled=True, created=100):
    return {"id": name + suffix, "name": name, "enabled": enabled, "createdAtMs": created}


class CronSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="openclaw-cron-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        subprocess.run([
            "rsync", "-a", str(ROOT / "scripts/setup-crons.sh"),
            str(ROOT / "scripts/load-local-env.sh"), str(self.root / "scripts") + "/",
        ], check=True, capture_output=True)
        (self.root / "oc").write_text(FAKE_OC)
        (self.root / "oc").chmod(0o700)
        self.state_path = self.root / "state.json"

    def run_setup(self, state, *args):
        self.state_path.write_text(json.dumps(state))
        env = os.environ.copy()
        env["FAKE_OC_STATE"] = str(self.state_path)
        result = subprocess.run(
            ["/bin/bash", str(self.root / "scripts/setup-crons.sh"), *args],
            env=env, text=True, capture_output=True, timeout=30,
        )
        return result, json.loads(self.state_path.read_text())

    def assert_no_mutations(self, state):
        self.assertTrue(all(call[1] == "list" for call in state.get("calls", [])))

    def test_duplicate_preflight_stops_before_any_mutation(self):
        jobs = [job(name) for name in NAMES] + [job(NAMES[-1], "-extra")]
        result, state = self.run_setup({"jobs": jobs})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Multiple enabled jobs", result.stderr)
        self.assert_no_mutations(state)

    def test_opt_in_keeps_oldest_enabled_and_retains_disabled_history(self):
        name = NAMES[0]
        jobs = [job(name, "-new", created=300), job(name, "-paused", False, 1),
                job(name, "-old", created=100)]
        jobs += [job(n) for n in NAMES[1:]]
        result, state = self.run_setup({"jobs": jobs}, "--disable-duplicates")
        self.assertEqual(result.returncode, 0, result.stderr)
        copies = {j["id"]: j for j in state["jobs"] if j["name"] == name}
        self.assertTrue(copies[name + "-old"]["enabled"])
        self.assertFalse(copies[name + "-new"]["enabled"])
        self.assertFalse(copies[name + "-paused"]["enabled"])
        self.assertEqual(len(copies), 3)
        second, repeated = self.run_setup(state)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(len(repeated["jobs"]), len(jobs))
        self.assertEqual(sum(c[1] == "disable" for c in repeated["calls"]), 1)

    def test_fresh_setup_is_idempotent_and_uses_command_payloads(self):
        result, state = self.run_setup({"jobs": []}, "--telegram-chat-id", "fixture-chat")
        self.assertEqual(result.returncode, 0, result.stderr)
        again, state = self.run_setup(state, "fixture-chat")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(len(state["jobs"]), 9)
        for call in state["calls"]:
            if call[1] in ("add", "edit"):
                self.assertIn("--command-argv", call)
                self.assertIn("--no-deliver", call)
                self.assertNotIn("--message", call)
                self.assertNotIn("--enable", call)

    def test_invalid_or_failed_discovery_never_creates_jobs(self):
        invalid = [
            {"fail_action": "list"},
            {"listing": "unparseable"},
            {"listing": "{}"},
            {"listing": '{"jobs":[],"hasMore":true}'},
            {"listing": '{"jobs":[],"total":1}'},
            {"listing": json.dumps({"jobs": [job(NAMES[0]), job(NAMES[0])]})},
            {"listing": '{"jobs":[{"id":"","name":"bad"}]}'},
            {"listing": '{"jobs":[{"id":"job","name":"bad","enabled":"false"}]}'},
        ]
        for overrides in invalid:
            with self.subTest(overrides=overrides):
                result, state = self.run_setup({"jobs": [], **overrides})
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_mutations(state)

    def test_known_sqlite_warning_prefix_does_not_hide_valid_listing(self):
        result, state = self.run_setup({
            "jobs": [job(n) for n in NAMES],
            "prefix": "[state/db] skipped permission hardening for fixture-wal: EPERM\n",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(state["jobs"]), len(NAMES))

    def test_paused_jobs_and_unmanaged_duplicates_stay_unchanged(self):
        jobs = [job(n, enabled=False) for n in NAMES]
        jobs += [job("digest-morning"), job("digest-morning", "-extra"),
                 job("custom"), job("custom", "-extra")]
        result, state = self.run_setup({"jobs": jobs}, "--disable-duplicates")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(not j["enabled"] for j in state["jobs"] if j["name"] in NAMES))
        self.assertEqual(state["jobs"][-4:], jobs[-4:])

    def test_digest_duplicates_require_opt_in_only_when_digest_is_managed(self):
        jobs = [job(n) for n in NAMES] + [job("digest-morning"), job("digest-morning", "-extra")]
        result, state = self.run_setup({"jobs": jobs}, "--telegram-chat-id", "fixture-chat")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_mutations(state)

    def test_failed_edit_does_not_disable_duplicate(self):
        jobs = [job(NAMES[0]), job(NAMES[0], "-extra")]
        result, state = self.run_setup({"jobs": jobs, "fail_action": "edit"}, "--disable-duplicates")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[1] == "disable" for c in state["calls"]))
        self.assertEqual(state["jobs"], jobs)

    def test_failed_refresh_stops_after_the_first_creation(self):
        result, state = self.run_setup({"jobs": [], "fail_list_after": 1})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(state["jobs"]), 1)
        self.assertEqual(sum(c[1] == "add" for c in state["calls"]), 1)

    def test_multiple_paused_copies_are_retained_without_enabling(self):
        jobs = [job(n, enabled=False) for n in NAMES]
        jobs += [job(NAMES[0], "-extra", False, 200)]
        result, state = self.run_setup({"jobs": jobs})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(state["jobs"]), len(jobs))
        self.assertTrue(all(not j["enabled"] for j in state["jobs"]))
        self.assertFalse(any(c[1] == "disable" for c in state["calls"]))

    def test_failed_disable_stops_remaining_setup(self):
        jobs = [job(NAMES[0]), job(NAMES[0], "-extra")]
        result, state = self.run_setup({"jobs": jobs, "fail_action": "disable"}, "--disable-duplicates")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["calls"][-1][1], "disable")
        self.assertFalse(any(c[1] == "add" for c in state["calls"]))

    def test_missing_option_value_stops_before_discovery(self):
        result, state = self.run_setup({"jobs": []}, "--telegram-chat-id")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_mutations(state)


if __name__ == "__main__":
    unittest.main()
