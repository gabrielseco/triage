"""Exercise observed lifecycle publication with real Git and a read-only gh stub."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid


SCRIPTS = Path(__file__).resolve().parents[1]


class TaskEventTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Events Test")
        self.git("config", "user.email", "events@example.com")
        self.git("remote", "add", "origin", "git@github.com:owner/project.git")
        (self.root / ".gitignore").write_text(".claude/tasks/\n")
        (self.root / "code").write_text("base")
        self.git("add", ".")
        self.git("commit", "-m", "base")
        self.git("branch", "origin/main")
        self.git("checkout", "-b", "feature")
        self.head = self.git("rev-parse", "HEAD")
        spec = Path(self.temp.name) / "spec.json"
        spec.write_text(json.dumps({"request": "Publish lifecycle", "criteria": [
            {"text": "Observed events publish", "proof": "Tests"}], "outOfScope": []}))
        self.cli("task-goal.py", "init", "event-task", "--input", str(spec))
        self.cli("task-goal.py", "approve", "event-task")
        self.directory = self.root / ".claude/tasks/event-task"
        self.log = self.directory / "events.jsonl"
        self.bin = Path(self.temp.name) / "bin"
        self.bin.mkdir()
        self.responses = Path(self.temp.name) / "responses.json"
        self.calls = Path(self.temp.name) / "calls.jsonl"
        stub = self.bin / "gh"
        stub.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                        "args=sys.argv[1:]\n"
                        "with open(os.environ['GH_CALLS'],'a') as f: f.write(json.dumps(args)+'\\n')\n"
                        "data=json.load(open(os.environ['GH_RESPONSES']))\n"
                        "if args==['repo','view','owner/project','--json','nameWithOwner']: key='repo'\n"
                        "elif args==['api','repos/owner/project/pulls/7']: key='pr'\n"
                        "elif args==['api','repos/owner/project/actions/runs/12']: key='run'\n"
                        "else: sys.exit(3)\n"
                        "if data.get('error')==key: sys.exit(2)\n"
                        "print(json.dumps(data[key]))\n")
        stub.chmod(0o755)
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "GH_RESPONSES": str(self.responses), "GH_CALLS": str(self.calls)}
        self.data = {"repo": {"nameWithOwner": "owner/project"}, "pr": {
            "number": 7, "html_url": "https://github.com/owner/project/pull/7",
            "created_at": "2026-10-01T01:02:03Z", "merged_at": None, "merge_commit_sha": None,
            "head": {"sha": self.head, "ref": "feature", "repo": {"full_name": "owner/project"}},
            "base": {"repo": {"full_name": "owner/project"}}}, "run": {
                "id": 12, "run_attempt": 1, "repository": {"full_name": "owner/project"},
                "head_sha": self.head, "head_branch": "feature", "pull_requests": [{"number": 7}],
                "status": "completed", "conclusion": "success", "event": "pull_request",
                "html_url": "https://github.com/owner/project/actions/runs/12",
                "updated_at": "2026-10-02T02:03:04Z"}}
        self.save()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, text=True, capture_output=True,
                              check=True).stdout.strip()

    def cli(self, script, *args, ok=True):
        result = subprocess.run([sys.executable, str(SCRIPTS / script), *args], cwd=self.root,
                                env=getattr(self, "env", None), text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode == 0, ok, result.stderr)
        return result

    def save(self):
        self.responses.write_text(json.dumps(self.data))

    def event_args(self, command="pr-created", head=None):
        args = [command, "event-task", "--pr", "7", "--head", head or self.head]
        if command == "ci-completed":
            args.extend(["--run", "12"])
        return args

    def publish(self, command="pr-created", ok=True, head=None):
        self.save()
        return self.cli("task-event.py", *self.event_args(command, head), ok=ok)

    def values(self):
        return [json.loads(line) for line in self.log.read_text().splitlines() if line.strip()]

    def reject(self, command="pr-created", head=None):
        before = self.log.read_bytes() if self.log.exists() else None
        self.publish(command, ok=False, head=head)
        self.assertEqual(self.log.read_bytes() if self.log.exists() else None, before)

    def test_lifecycle_and_read_only_commands(self):
        self.publish()
        self.publish("ci-completed")
        self.data["pr"].update(merged_at="2026-10-03T03:04:05Z", merge_commit_sha="a" * 40)
        self.publish("pr-merged")
        events = self.values()
        self.assertEqual([item["kind"] for item in events], ["pr.created", "ci.completed", "pr.merged"])
        self.assertEqual(events[1]["payload"]["status"], "success")
        self.assertEqual(events[2]["payload"]["mergeCommit"], "a" * 40)
        for item in events:
            self.assertEqual(item["schemaVersion"], 1)
            self.assertEqual(item["taskID"], "event-task")
            self.assertEqual(item["payload"]["headCommit"], self.head)
            self.assertEqual(item["payload"]["number"], "7")
            uuid.UUID(item["id"])
            self.assertTrue(all(isinstance(value, str) for value in item["payload"].values()))
        for args in map(json.loads, self.calls.read_text().splitlines()):
            self.assertIn(args[0], ("repo", "api"))
            self.assertNotIn("--method", args)
            if args[0] == "repo":
                self.assertEqual(args, ["repo", "view", "owner/project", "--json", "nameWithOwner"])
                self.assertNotIn("--repo", args)

    def test_retry_noop_and_creation_preserves_original_revision(self):
        self.publish()
        original = self.log.read_bytes()
        self.publish()
        self.git("commit", "--allow-empty", "-m", "revision")
        revised = self.git("rev-parse", "HEAD")
        self.data["pr"]["head"]["sha"] = revised
        self.publish(head=revised)
        self.publish(head=self.head)
        self.assertEqual(self.log.read_bytes(), original)
        self.data["run"]["head_sha"] = revised
        self.publish("ci-completed", head=revised)
        self.assertEqual(self.values()[0]["payload"]["headCommit"], self.head)
        self.assertEqual(self.values()[1]["payload"]["headCommit"], revised)

    def test_origin_forms_and_mismatched_remote(self):
        for origin in ("https://github.com/owner/project.git", "https://github.com/owner/project",
                       "ssh://git@github.com/owner/project.git"):
            self.git("remote", "set-url", "origin", origin)
            self.publish()
        self.git("remote", "set-url", "origin", "https://github.com/other/project.git")
        self.reject()
        self.git("remote", "set-url", "origin", "https://example.com/owner/project.git")
        self.reject()

    def test_same_ci_attempt_cannot_change_revision(self):
        self.publish()
        self.publish("ci-completed")
        self.git("commit", "--allow-empty", "-m", "revision")
        revised = self.git("rev-parse", "HEAD")
        self.data["pr"]["head"]["sha"] = revised
        self.data["run"]["head_sha"] = revised
        self.reject("ci-completed", head=revised)

    def test_terminal_conclusions_attempts_and_contradictions(self):
        self.publish()
        for attempt, conclusion in enumerate(("failure", "cancelled", "success"), 1):
            self.data["run"].update(run_attempt=attempt, conclusion=conclusion)
            self.publish("ci-completed")
            original = self.log.read_bytes()
            self.publish("ci-completed")
            self.assertEqual(self.log.read_bytes(), original)
        self.assertEqual([item["payload"]["status"] for item in self.values()[1:]],
                         ["failure", "cancelled", "success"])
        self.data["run"]["conclusion"] = "failure"
        self.reject("ci-completed")
        self.data["pr"]["created_at"] = "2026-10-02T01:02:03Z"
        self.reject()

    def test_pending_and_null_conclusion_do_not_append(self):
        self.publish()
        original = self.log.read_bytes()
        for status, conclusion in (("queued", None), ("in_progress", "success"), ("completed", None)):
            self.data["run"].update(status=status, conclusion=conclusion)
            self.publish("ci-completed")
            self.assertEqual(self.log.read_bytes(), original)

    def test_empty_associations_require_matching_pull_request_or_push_event(self):
        self.publish()
        self.data["run"]["pull_requests"] = []
        self.data["run"]["event"] = "workflow_dispatch"
        self.reject("ci-completed")
        self.data["run"]["event"] = "pull_request"
        self.publish("ci-completed")
        self.data["run"].update(event="push", run_attempt=2)
        self.publish("ci-completed")
        self.data["run"]["pull_requests"] = [{"number": 8}]
        self.reject("ci-completed")

    def test_remote_identity_and_revision_mismatch(self):
        self.publish()
        original = copy.deepcopy(self.data)
        changes = [("repo", "nameWithOwner", "other/project"), ("pr", "number", 8),
                   ("pr", "html_url", "https://example.com"), ("run", "id", 13),
                   ("run", "head_branch", "other"), ("run", "head_sha", "b" * 40),
                   ("run", "html_url", "https://example.com"), ("run", "run_attempt", True),
                   ("run", "status", "unknown"), ("run", "conclusion", "unknown"),
                   ("run", "updated_at", "yesterday")]
        for resource, key, value in changes:
            with self.subTest(key=key):
                self.data = copy.deepcopy(original)
                self.data[resource][key] = value
                self.reject("ci-completed")
        for side in ("base", "head"):
            self.data = copy.deepcopy(original)
            self.data["pr"][side]["repo"]["full_name"] = "other/project"
            self.reject()
        self.data = copy.deepcopy(original)
        self.data["pr"]["head"]["ref"] = "other"
        self.reject()
        self.data = copy.deepcopy(original)
        self.data["run"]["repository"]["full_name"] = "other/project"
        self.reject("ci-completed")
        self.data = copy.deepcopy(original)
        self.reject("ci-completed", head="b" * 40)
        self.reject("ci-completed", head="HEAD")

    def test_creation_requires_current_head_and_merge_requires_observed_merge(self):
        self.data["pr"]["head"]["sha"] = "a" * 40
        self.reject()
        self.reject(head="a" * 40)
        self.data["pr"]["head"]["sha"] = self.head
        self.reject("ci-completed")
        self.reject("pr-merged")
        self.publish()
        self.reject("pr-merged")
        self.data["pr"]["merged_at"] = "2026-10-03T03:04:05Z"
        self.reject("pr-merged")
        self.data["pr"]["merge_commit_sha"] = "a" * 40
        self.publish("pr-merged")
        self.data["pr"]["merge_commit_sha"] = "b" * 40
        self.reject("pr-merged")

    def test_malformed_history_preserved_and_extensible_history_accepted(self):
        self.publish()
        original = self.log.read_bytes()
        event = self.values()[0]
        bad = [b'{', original.rstrip(b'\n'), b'\xff\n', b'[]\n']
        for change in ({"schemaVersion": 2}, {"schemaVersion": True}, {"taskID": "other"},
                       {"id": "invalid"}, {"timestamp": "yesterday"}, {"kind": ""},
                       {"payload": {"value": 1}}, {"payload": []}):
            bad.append((json.dumps({**event, **change}) + "\n").encode())
        bad.append(original + original)
        for content in bad:
            with self.subTest(content=content):
                self.log.write_bytes(content)
                self.reject()
        unknown = {**event, "id": str(uuid.uuid4()), "kind": "future.event", "additional": 1,
                   "payload": {"custom": "value"}}
        self.log.write_bytes(b'\n' + (json.dumps(unknown) + "\n").encode())
        self.publish()
        self.assertEqual(self.values()[0], unknown)
        self.assertEqual(len(self.values()), 2)

    def test_nonregular_event_paths_rejected_without_blocking(self):
        self.publish()
        self.log.unlink()
        os.mkfifo(self.log)
        self.publish(ok=False)
        self.log.unlink()
        self.log.mkdir()
        self.publish(ok=False)
        self.log.rmdir()
        lock = self.directory / ".events.lock"
        lock.unlink()
        os.mkfifo(lock)
        self.publish(ok=False)

    def test_symlink_artifacts_and_task_directories_rejected(self):
        self.publish()
        original = self.log.read_bytes()
        outside = Path(self.temp.name) / "outside"
        outside.write_bytes(original)
        self.log.unlink()
        self.log.symlink_to(outside)
        self.publish(ok=False)
        self.assertEqual(outside.read_bytes(), original)
        self.log.unlink()
        self.log.write_bytes(original)
        lock = self.directory / ".events.lock"
        lock.unlink()
        lock.symlink_to(outside)
        self.publish(ok=False)
        self.assertEqual(outside.read_bytes(), original)
        lock.unlink()
        moved = self.directory.with_name("moved")
        self.directory.rename(moved)
        self.directory.symlink_to(moved, target_is_directory=True)
        self.publish(ok=False)
        self.assertEqual((moved / "events.jsonl").read_bytes(), original)

    def test_branch_goal_slug_and_observation_errors_preserve_history(self):
        self.publish()
        self.data["error"] = "pr"
        self.reject()
        del self.data["error"]
        manifest = self.directory / "goal.json"
        approved = manifest.read_bytes()
        value = json.loads(approved)
        value["status"] = "draft"
        manifest.write_text(json.dumps(value))
        self.reject()
        manifest.write_bytes(approved)
        self.git("checkout", "-b", "other")
        self.reject()
        self.git("checkout", "feature")
        for slug in ("../outside", "UPPER", "under_score"):
            args = self.event_args()
            args[1] = slug
            self.cli("task-event.py", *args, ok=False)

    def test_concurrent_duplicate_and_distinct_events(self):
        self.publish()
        self.data["pr"].update(merged_at="2026-10-03T03:04:05Z", merge_commit_sha="a" * 40)
        self.save()
        commands = ["pr-created", "ci-completed", "pr-merged"] * 4
        processes = [subprocess.Popen([sys.executable, str(SCRIPTS / "task-event.py"), *self.event_args(command)],
                                      cwd=self.root, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      text=True) for command in commands]
        for process in processes:
            _, error = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, error)
        self.assertEqual(len(self.values()), 3)
        self.assertTrue(self.log.read_bytes().endswith(b"\n"))
        self.assertEqual(len({item["id"] for item in self.values()}), 3)


if __name__ == "__main__":
    unittest.main()
