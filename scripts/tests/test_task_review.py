"""Exercise review publication with disposable real Git repositories."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]


class TaskReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        self.input = Path(self.temp.name) / "input.json"
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Review Test")
        self.git("config", "user.email", "review@example.com")
        (self.root / ".gitignore").write_text(".claude/tasks/\n")
        (self.root / "code.txt").write_text("original\n")
        self.git("add", ".")
        self.git("commit", "-m", "base")
        self.git("branch", "origin/main")
        self.git("checkout", "-b", "feature")
        self.write_input({"request": "Record reviews", "criteria": [
            {"text": "Complete reviews publish", "proof": "Behavior tests"}], "outOfScope": []})
        self.cli("task-goal.py", "init", "review-task", "--input", str(self.input))
        self.cli("task-goal.py", "approve", "review-task")
        (self.root / "code.txt").write_text("implemented\n")
        self.git("add", ".")
        self.snapshot()
        self.value = {"schemaVersion": 1, "taskID": "review-task", "source": "pr-review",
                      "status": "complete", "findings": [], "provenance":
                      json.loads(self.artifact("review-inputs").read_text())}
        self.record()
        self.original = self.artifact("reviews").read_bytes()

    def git(self, *args):
        result = subprocess.run(["git", *args], cwd=self.root, text=True,
                                capture_output=True, check=True)
        return result.stdout.strip()

    def cli(self, script, *args, ok=True):
        result = subprocess.run([sys.executable, str(SCRIPTS / script), *args], cwd=self.root,
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode == 0, ok, result.stderr)
        return result

    def write_input(self, value):
        self.input.write_text(json.dumps(value))

    def artifact(self, directory):
        return self.root / ".claude/tasks/review-task" / directory / "pr-review.json"

    def snapshot(self, *args, ok=True):
        return self.cli("task-review.py", "snapshot", "review-task", "pr-review", *args, ok=ok)

    def record(self, value=None, ok=True):
        self.write_input(self.value if value is None else value)
        return self.cli("task-review.py", "record", "review-task", "pr-review",
                        "--input", str(self.input), ok=ok)

    def reject(self, value=None):
        self.record(value, ok=False)
        self.assertEqual(self.artifact("reviews").read_bytes(), self.original)

    def test_empty_and_findings_preserve_unknown_metadata(self):
        self.assertEqual(json.loads(self.original), self.value)
        self.value["reviewer"] = {"session": "independent"}
        self.value["findings"] = [{"severity": "blocking", "message": "Fix the issue",
                                   "file": "Sources/Core.swift", "line": 2,
                                   "evidence": ["A failing test"], "githubCommentID": 123},
                                  {"severity": "warning", "message": "Consider this"},
                                  {"severity": "suggestion", "message": "Optional"}]
        self.record()
        self.assertEqual(json.loads(self.artifact("reviews").read_text()), self.value)

    def test_invalid_top_level_and_provenance_leave_previous_review(self):
        for change in ({"schemaVersion": True}, {"schemaVersion": 2}, {"taskID": "wrong"},
                       {"source": "design-review"}, {"status": "pending"},
                       {"findings": {}}, {"findings": [None]}, {"provenance": {}}):
            with self.subTest(change=change):
                self.reject({**self.value, **change})
        self.reject([])
        value = copy.deepcopy(self.value)
        value["provenance"]["schemaVersion"] = True
        self.reject(value)

    def test_invalid_finding_metadata_leave_previous_review(self):
        valid = {"severity": "blocking", "message": "Issue"}
        changes = [{"severity": "error"}, {"message": " "}, {"message": 1},
                   {"file": "/tmp/file"}, {"file": "../file"}, {"file": "a/../b"},
                   {"file": "a\\b"}, {"file": "a\0b"}, {"file": "a//b"},
                   {"file": ""}, {"file": None}, {"line": 1},
                   {"file": "code.txt", "line": True}, {"file": "code.txt", "line": 0},
                   {"file": "code.txt", "line": "1"}, {"evidence": "proof"},
                   {"evidence": [""]}, {"evidence": [1]}]
        for change in changes:
            with self.subTest(change=change):
                self.reject({**self.value, "findings": [{**valid, **change}]})

    def test_invalid_slugs(self):
        for slug in ("../outside", "UPPER", "under_score", "a/b"):
            self.cli("task-review.py", "snapshot", slug, "pr-review", ok=False)
            self.cli("task-review.py", "snapshot", "review-task", slug, ok=False)
            self.cli("task-review.py", "record", "review-task", slug,
                     "--input", str(self.input), ok=False)
        self.assertEqual(self.artifact("reviews").read_bytes(), self.original)

    def test_stale_tree_unstaged_and_untracked(self):
        (self.root / "code.txt").write_text("changed\n")
        self.reject()
        self.snapshot(ok=False)
        self.git("add", "code.txt")
        self.reject()
        (self.root / "code.txt").write_text("implemented\n")
        self.git("add", "code.txt")
        (self.root / "new.txt").write_text("untracked")
        self.reject()
        self.snapshot(ok=False)

    def test_stale_goal_and_branch(self):
        manifest = self.artifact("reviews").parents[1] / "goal.json"
        original_goal = manifest.read_bytes()
        value = json.loads(original_goal)
        value["extra"] = "new metadata"
        manifest.write_text(json.dumps(value))
        self.reject()
        manifest.write_bytes(original_goal)
        markdown = manifest.with_name("goal.md")
        markdown.write_text(markdown.read_text() + "Unauthorized change\n")
        self.reject()

    def test_different_branch(self):
        self.git("checkout", "-b", "other")
        self.reject()

    def test_commit_with_same_tree_remains_valid_and_head_is_bound(self):
        self.git("commit", "-m", "implemented")
        self.record()
        self.snapshot("--head", "HEAD")
        self.value["provenance"] = json.loads(self.artifact("review-inputs").read_text())
        self.assertEqual(self.value["provenance"]["headCommit"], self.git("rev-parse", "HEAD"))
        self.record()
        self.git("commit", "--allow-empty", "-m", "same tree")
        self.record()  # The reviewed commit remains valid while the tree is unchanged.
        before = self.artifact("review-inputs").read_bytes()
        self.snapshot("--head", "origin/main", ok=False)
        self.assertEqual(self.artifact("review-inputs").read_bytes(), before)

    def test_explicit_base_and_stale_snapshot(self):
        self.git("commit", "-m", "implemented")
        self.snapshot("--base", "HEAD")
        self.reject()  # Old result must not overwrite the previous review.
        self.value["provenance"] = json.loads(self.artifact("review-inputs").read_text())
        self.assertEqual(self.value["provenance"]["baseCommit"], self.git("rev-parse", "HEAD"))
        self.record()

    def test_symlink_directories_and_artifacts(self):
        for name in ("review-inputs", "reviews"):
            path = self.artifact(name)
            original_bytes = path.read_bytes()
            target = Path(self.temp.name) / f"{name}.json"
            target.write_bytes(original_bytes)
            path.unlink()
            path.symlink_to(target)
            self.snapshot(ok=False)
            self.record(ok=False)
            self.assertEqual(target.read_bytes(), original_bytes)
            path.unlink()
            path.write_bytes(original_bytes)
            parent = path.parent
            moved = Path(self.temp.name) / name
            parent.rename(moved)
            parent.symlink_to(moved, target_is_directory=True)
            self.snapshot(ok=False)
            self.record(ok=False)
            self.assertEqual((moved / path.name).read_bytes(), original_bytes)
            parent.unlink()
            moved.rename(parent)
        self.input.unlink()
        target = Path(self.temp.name) / "external.json"
        target.write_text(json.dumps(self.value))
        self.input.symlink_to(target)
        self.record(ok=False)

    def test_unapproved_goal(self):
        manifest = self.artifact("reviews").parents[1] / "goal.json"
        value = json.loads(manifest.read_text())
        value["status"] = "draft"
        manifest.write_text(json.dumps(value))
        self.snapshot(ok=False)
        self.reject()


if __name__ == "__main__":
    unittest.main()
