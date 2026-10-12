import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / ".claude/hooks/require-goal.py"
SPEC = importlib.util.spec_from_file_location("require_goal", HOOK)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class GoalHookTests(unittest.TestCase):
    def test_ordinary_invocations_and_quoted_worktree_paths(self):
        with tempfile.TemporaryDirectory(prefix="goal hook ") as directory:
            for command in ("gh pr create --body 'A PR'", "X=1 gh pr create",
                            "env X=1 gh pr create", "command gh pr create",
                            "env -i gh pr create", "env --unset=VARIABLE gh pr create",
                            "env -u VARIABLE gh pr create", "command -p gh pr create",
                            "exec gh pr create", "exec -a gh gh pr create",
                            "builtin exec gh pr create", "/usr/bin/env -i gh pr create",
                            "/usr/local/bin/gh pr create", "gh --repo owner/repo pr create"):
                with self.subTest(command=command):
                    self.assertEqual(list(MODULE.creations(command, directory)), [Path(directory)])
            command = f"cd '{directory}' && gh pr create --body 'Title; more'"
            self.assertEqual(list(MODULE.creations(command, "/tmp")), [Path(directory).resolve()])
            command = f"env --chdir '{directory}' gh pr create"
            self.assertEqual(list(MODULE.creations(command, "/tmp")), [Path(directory).resolve()])

    def test_non_creation_commands_do_not_require_a_goal(self):
        for command in ("git status", "gh pr view 54", "echo 'gh pr create'",
                        "git commit -m 'gh pr create'", "gh pr edit --body 'gh pr create'",
                        'cd "$REPO" && swift test', 'cd "$REPO" && gh pr view 54'):
            with self.subTest(command=command):
                self.assertEqual(list(MODULE.creations(command, "/tmp")), [])

    def test_unknown_env_option_fails_closed_before_creation(self):
        with self.assertRaises(ValueError):
            list(MODULE.creations("env --unknown gh pr create", "/tmp"))

    def test_creation_without_verified_goal_is_blocked(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(["git", "init", directory], capture_output=True, check=True)
            event = {"cwd": directory, "tool_input": {"command": "gh pr create"}}
            result = subprocess.run(["python3", str(HOOK)], input=json.dumps(event),
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 2)

    def test_invalid_hook_input_fails_closed(self):
        result = subprocess.run(["python3", str(HOOK)], input="{", capture_output=True,
                                text=True, check=False)
        self.assertEqual(result.returncode, 2)

    def test_prepush_blocks_other_branch_and_unverified_delivery(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.git(repo, "init", "-b", "feature")
            self.git(repo, "config", "user.name", "Test")
            self.git(repo, "config", "user.email", "test@example.com")
            (repo / "change.txt").write_text("change")
            scripts = repo / "scripts"
            scripts.mkdir()
            (scripts / "task-goal.py").write_bytes((ROOT / "scripts/task-goal.py").read_bytes())
            self.git(repo, "add", ".")
            self.git(repo, "commit", "-m", "fixture")
            sha = self.git(repo, "rev-parse", "HEAD")
            for local_ref in ("refs/heads/other", "refs/heads/feature"):
                with self.subTest(local_ref=local_ref):
                    result = subprocess.run(["bash", str(ROOT / ".githooks/pre-push")], cwd=repo,
                                            input=f"{local_ref} {sha} refs/heads/feature {'0' * 40}\n",
                                            capture_output=True, text=True, check=False)
                    self.assertNotEqual(result.returncode, 0)
            self.git(repo, "checkout", "--detach")
            result = subprocess.run(["bash", str(ROOT / ".githooks/pre-push")], cwd=repo,
                                    input=f"refs/tags/v1 {sha} refs/tags/v1 {'0' * 40}\n",
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)

    @staticmethod
    def git(repo, *arguments):
        return subprocess.run(["git", "-C", str(repo), *arguments], capture_output=True,
                              text=True, check=True).stdout.strip()


if __name__ == "__main__":
    unittest.main()
