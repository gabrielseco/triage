"""Exercise delivery validation against real disposable Git repositories."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "task-goal.py"


class TaskGoalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Goal Test")
        self.git("config", "user.email", "goal@example.com")
        (self.root / ".gitignore").write_text(".claude/tasks/\n")
        (self.root / "code.txt").write_text("original\n")
        self.git("add", ".")
        self.git("commit", "-m", "base")
        self.git("branch", "origin/main")
        self.git("checkout", "-b", "feature")
        self.spec = {"request": "Build the requested feature", "criteria": [
            {"text": "Works as requested", "proof": "Run a behavioral test"},
            {"text": "Preserves existing behavior", "proof": "Run regression tests"}],
            "outOfScope": ["Unrelated changes"]}
        # Input files live outside the repository, so they do not dirty delivery.
        self.inputs = tempfile.TemporaryDirectory()
        self.addCleanup(self.inputs.cleanup)
        self.input = Path(self.inputs.name) / "input.json"

    def git(self, *args):
        result = subprocess.run(["git", *args], cwd=self.root, text=True,
                                capture_output=True, check=True)
        return result.stdout.strip()

    def run_cli(self, *args, ok=True):
        result = subprocess.run([sys.executable, str(SCRIPT), *args], cwd=self.root,
                                text=True, capture_output=True, check=False)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def write_input(self, value):
        self.input.write_text(json.dumps(value))
        return str(self.input)

    def artifact(self, name, slug="feature-goal"):
        return self.root / ".claude" / "tasks" / slug / name

    def init_goal(self, slug="feature-goal", approve=True):
        self.run_cli("init", slug, "--input", self.write_input(self.spec))
        if approve:
            self.run_cli("approve", slug)

    def prepare(self):
        self.init_goal()
        (self.root / "code.txt").write_text("implemented\n")
        self.git("add", "code.txt")
        self.run_cli("snapshot", "feature-goal")
        self.verdict = {"schemaVersion": 1, "taskID": "feature-goal", "verdict": "pass",
                        "criteria": [{"text": criterion["text"], "pass": True,
                                      "evidence": ["Behavioral test passed"]}
                                     for criterion in self.spec["criteria"]],
                        "provenance": json.loads(self.artifact("verification-input.json").read_text())}

    def record(self, verdict=None, ok=True):
        return self.run_cli("record", "feature-goal", "--input",
                            self.write_input(verdict if verdict is not None else self.verdict), ok=ok)

    def test_complete_flow_survives_commit_and_preserves_provenance(self):
        self.prepare()
        self.verdict["verifier"] = {"session": "independent-session"}
        self.record()
        self.assertEqual(json.loads(self.artifact("verdict.json").read_text()), self.verdict)
        self.run_cli("check")
        self.git("commit", "-m", "implemented")
        self.run_cli("check", "feature-goal")

    def test_no_task_and_ambiguous_tasks_fail(self):
        self.run_cli("check", ok=False)
        self.prepare()
        self.record()
        self.init_goal("another-goal")
        self.assertIn("found 2", self.run_cli("check", ok=False).stderr)
        self.run_cli("check", "feature-goal")

    def test_unapproved_and_duplicate_approval_fail(self):
        self.init_goal(approve=False)
        self.run_cli("snapshot", "feature-goal", ok=False)
        self.run_cli("approve", "feature-goal")
        self.run_cli("approve", "feature-goal", ok=False)
        self.run_cli("init", "feature-goal", "--input", self.write_input(self.spec), ok=False)

    def test_staged_changes_invalidate_snapshot_and_record(self):
        self.prepare()
        self.record()
        (self.root / "code.txt").write_text("changed after verification\n")
        self.git("add", "code.txt")
        self.assertIn("stale", self.run_cli("check", ok=False).stderr)
        self.record(ok=False)

    def test_unstaged_changes_and_untracked_files_fail(self):
        self.prepare()
        self.record()
        (self.root / "code.txt").write_text("unstaged\n")
        self.assertIn("unstaged", self.run_cli("check", ok=False).stderr)
        self.run_cli("snapshot", "feature-goal", ok=False)
        (self.root / "code.txt").write_text("implemented\n")
        (self.root / "new.txt").write_text("new\n")
        self.assertIn("untracked", self.run_cli("check", ok=False).stderr)

    def test_goal_markdown_changes_fail(self):
        self.prepare()
        self.record()
        with self.artifact("goal.md").open("a") as output:
            output.write("Changed criteria\n")
        self.run_cli("check", ok=False)
        self.run_cli("snapshot", "feature-goal", ok=False)

    def test_manifest_changes_fail_even_when_rendered_goal_is_identical(self):
        self.prepare()
        self.record()
        goal = json.loads(self.artifact("goal.json").read_text())
        goal["extra"] = "changed"
        self.artifact("goal.json").write_text(json.dumps(goal))
        self.assertIn("stale", self.run_cli("check", ok=False).stderr)

    def test_criteria_manifest_changes_fail_before_new_snapshot(self):
        self.prepare()
        goal = json.loads(self.artifact("goal.json").read_text())
        goal["criteria"][0]["text"] = "Different criterion"
        self.artifact("goal.json").write_text(json.dumps(goal))
        self.run_cli("snapshot", "feature-goal", ok=False)

    def test_verdict_mismatch_and_missing_proof_rejected(self):
        self.prepare()
        variants = []
        value = copy.deepcopy(self.verdict)
        value["taskID"] = "different-goal"
        variants.append(value)
        value = copy.deepcopy(self.verdict)
        value["criteria"].reverse()
        variants.append(value)
        value = copy.deepcopy(self.verdict)
        value["criteria"][0]["evidence"] = []
        variants.append(value)
        value = copy.deepcopy(self.verdict)
        value["criteria"][0]["pass"] = 1
        variants.append(value)
        value = copy.deepcopy(self.verdict)
        value["provenance"]["tree"] = "wrong"
        variants.append(value)
        value = copy.deepcopy(self.verdict)
        value["schemaVersion"] = True
        variants.append(value)
        for value in variants:
            with self.subTest(value=value):
                self.record(value, ok=False)

    def test_failed_verdict_can_be_recorded_but_cannot_deliver(self):
        self.prepare()
        self.verdict["verdict"] = "fail"
        self.verdict["criteria"][0].update({"pass": False, "evidence": []})
        self.record()
        self.assertIn("passing verdict", self.run_cli("check", ok=False).stderr)

    def test_passing_verdict_with_failures_or_issues_rejected(self):
        self.prepare()
        for key in ("missing", "unexpected", "concerns"):
            value = copy.deepcopy(self.verdict)
            value[key] = ["Needs attention"]
            self.record(value, ok=False)
        self.verdict["criteria"][0]["pass"] = False
        self.record(ok=False)

    def test_check_revalidates_manually_edited_verdict(self):
        self.prepare()
        self.record()
        self.verdict["criteria"][0]["evidence"] = []
        self.artifact("verdict.json").write_text(json.dumps(self.verdict))
        self.run_cli("check", ok=False)

    def test_invalid_slugs_and_specs_fail(self):
        for slug in ("../outside", "UPPER", "has_space", "a/b"):
            self.run_cli("init", slug, "--input", self.write_input(self.spec), ok=False)
        for change in ({"criteria": []}, {"request": ""}, {"outOfScope": "wrong"},
                       {"criteria": [self.spec["criteria"][0]] * 2},
                       {"criteria": [{"text": "Criterion", "proof": ""}]}):
            value = {**self.spec, **change}
            self.run_cli("init", "feature-goal", "--input", self.write_input(value), ok=False)

    def test_different_branch_and_tampered_base_fail(self):
        self.prepare()
        self.record()
        self.git("checkout", "-b", "another-branch")
        self.run_cli("check", "feature-goal", ok=False)
        self.git("checkout", "feature")
        goal = json.loads(self.artifact("goal.json").read_text())
        goal["baseCommit"] = "0" * 40
        self.artifact("goal.json").write_text(json.dumps(goal))
        self.run_cli("check", "feature-goal", ok=False)

    def test_subdirectory_invocation_checks_entire_repository(self):
        self.prepare()
        self.record()
        subdirectory = self.root / "nested"
        subdirectory.mkdir()
        (self.root / "outside-subdirectory.txt").write_text("untracked\n")
        result = subprocess.run([sys.executable, str(SCRIPT), "check"], cwd=subdirectory,
                                text=True, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("untracked", result.stderr)

    def test_whitespace_only_untracked_filename_is_detected(self):
        self.prepare()
        self.record()
        (self.root / " ").write_text("untracked\n")
        self.assertIn("untracked", self.run_cli("check", ok=False).stderr)

    def test_revision_archives_exact_artifacts_and_requires_new_approval_and_review(self):
        self.prepare()
        self.record()
        names = ("goal.md", "goal.json", "verification-input.json", "verdict.json")
        original = {name: self.artifact(name).read_bytes() for name in names}
        revised_spec = copy.deepcopy(self.spec)
        revised_spec["criteria"][0]["text"] = "New authorized requirement"
        reason = "User requested the additional requirement"
        self.run_cli("revise", "feature-goal", "--input", self.write_input(revised_spec),
                     "--reason", reason)
        archives = list(self.artifact("history").iterdir())
        self.assertEqual(len(archives), 1)
        for name, content in original.items():
            self.assertEqual((archives[0] / name).read_bytes(), content)
        goal = json.loads(self.artifact("goal.json").read_text())
        self.assertEqual(goal["status"], "draft")
        self.assertEqual(goal["changesAfterApproval"], [reason])
        self.assertNotIn("approvedGoalSHA256", goal)
        self.assertIn(reason, self.artifact("goal.md").read_text())
        self.assertFalse(self.artifact("verification-input.json").exists())
        self.assertFalse(self.artifact("verdict.json").exists())
        self.run_cli("check", ok=False)
        self.run_cli("snapshot", "feature-goal", ok=False)
        self.run_cli("approve", "feature-goal")
        self.run_cli("check", ok=False)
        self.run_cli("snapshot", "feature-goal")
        self.record(ok=False)  # The old verifier response cannot be reused.
        self.verdict["criteria"][0]["text"] = revised_spec["criteria"][0]["text"]
        self.verdict["provenance"] = json.loads(self.artifact("verification-input.json").read_text())
        self.record()
        self.run_cli("check")
        self.run_cli("revise", "feature-goal", "--input", self.write_input(revised_spec),
                     "--reason", "Second authorized revision")
        goal = json.loads(self.artifact("goal.json").read_text())
        self.assertEqual(goal["changesAfterApproval"], [reason, "Second authorized revision"])
        self.assertEqual(len(list(self.artifact("history").iterdir())), 2)

    def test_invalid_revision_does_not_modify_existing_artifacts(self):
        self.prepare()
        self.record()
        names = ("goal.md", "goal.json", "verification-input.json", "verdict.json")
        original = {name: self.artifact(name).read_bytes() for name in names}
        self.run_cli("revise", "feature-goal", "--input", self.write_input({**self.spec, "criteria": []}),
                     "--reason", "Update criteria", ok=False)
        self.run_cli("revise", "feature-goal", "--input", self.write_input(self.spec),
                     "--reason", " ", ok=False)
        self.assertFalse(self.artifact("history").exists())
        for name, content in original.items():
            self.assertEqual(self.artifact(name).read_bytes(), content)
        self.run_cli("check")

    def test_revision_refuses_stale_goal_and_symlink_history(self):
        self.prepare()
        original = self.artifact("goal.md").read_text()
        self.artifact("goal.md").write_text(original + "Unauthorized edit\n")
        self.run_cli("revise", "feature-goal", "--input", self.write_input(self.spec),
                     "--reason", "Update criteria", ok=False)
        self.artifact("goal.md").write_text(original)
        self.artifact("history").symlink_to(Path(self.inputs.name))
        self.run_cli("revise", "feature-goal", "--input", self.write_input(self.spec),
                     "--reason", "Update criteria", ok=False)

    def test_symlink_task_artifacts_rejected(self):
        self.prepare()
        target = Path(self.inputs.name) / "goal-copy.json"
        target.write_bytes(self.artifact("goal.json").read_bytes())
        self.artifact("goal.json").unlink()
        self.artifact("goal.json").symlink_to(target)
        self.run_cli("snapshot", "feature-goal", ok=False)
        self.run_cli("check", ok=False)


if __name__ == "__main__":
    unittest.main()
