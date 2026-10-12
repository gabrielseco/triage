#!/usr/bin/env python3
"""Create approved task goals and bind independent verdicts to the staged Git tree."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid


REPOSITORY_ROOT = None


class GoalError(Exception):
    """A goal cannot be delivered with the supplied evidence."""


def git(*args):
    command = ["git"]
    if REPOSITORY_ROOT is not None:
        command.extend(["-C", str(REPOSITORY_ROOT)])
    result = subprocess.run([*command, *args], capture_output=True, text=True, check=False)
    if result.returncode:
        raise GoalError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def strings(value, label, nonempty=False):
    if not isinstance(value, list) or any(not isinstance(s, str) or not s.strip() for s in value):
        raise GoalError(f"{label} must be an array of nonempty strings")
    if nonempty and not value:
        raise GoalError(f"{label} must not be empty")
    return value


def required_text(value, label):
    if not isinstance(value, str) or not value.strip():
        raise GoalError(f"{label} must be a nonempty string")
    return value


def load_json(path):
    try:
        value = json.loads(path.read_text())
    except (OSError, UnicodeError, ValueError) as error:
        raise GoalError(f"cannot read {path.name}: {error}") from error
    if not isinstance(value, dict):
        raise GoalError(f"{path.name} must contain a JSON object")
    return value


def write_json(path, value):
    """Publish without exposing a partial document."""
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(value, output, indent=2, ensure_ascii=False)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def digest(path):
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as error:
        raise GoalError(f"cannot read {path.name}: {error}") from error


def task_directory(slug):
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", slug):
        raise GoalError("task ID must be a lowercase kebab slug")
    root = Path(git("rev-parse", "--show-toplevel"))
    directory = root / ".claude" / "tasks" / slug
    for path in (root / ".claude", root / ".claude" / "tasks", directory):
        if path.is_symlink():
            raise GoalError(f"task directories must not be symlinks: {path}")
    if directory.exists():
        for name in ("goal.md", "goal.json", "verification-input.json", "verdict.json"):
            if (directory / name).is_symlink():
                raise GoalError(f"task artifacts must not be symlinks: {name}")
    return directory


def validate_spec(value):
    required_text(value.get("request"), "request")
    criteria = value.get("criteria")
    if not isinstance(criteria, list) or not criteria:
        raise GoalError("criteria must be a nonempty array")
    texts = []
    for criterion in criteria:
        if not isinstance(criterion, dict):
            raise GoalError("each criterion must be an object")
        texts.append(required_text(criterion.get("text"), "criterion text"))
        required_text(criterion.get("proof"), "criterion proof")
    if len(set(text.strip() for text in texts)) != len(texts):
        raise GoalError("criterion texts must be unique")
    strings(value.get("outOfScope"), "outOfScope")


def render_goal(goal):
    lines = [f"# Goal: {goal['taskID']}", "", f"Branch: {goal['branch']}",
             f"Base commit: {goal['baseCommit']}", "", "## Request", "", goal["request"],
             "", "## Acceptance criteria", ""]
    for index, criterion in enumerate(goal["criteria"], 1):
        lines.extend([f"{index}. {criterion['text']}", f"   Evidence required: {criterion['proof']}"])
    lines.extend(["", "## Out of scope", ""])
    lines.extend(f"- {scope}" for scope in goal["outOfScope"])
    if not goal["outOfScope"]:
        lines.append("None specified.")
    changes = goal.get("changesAfterApproval", [])
    if changes:
        lines.extend(["", "## Goal changes", ""])
        lines.extend(f"- {reason}" for reason in changes)
    return "\n".join(lines) + "\n"


def branch():
    name = git("symbolic-ref", "--quiet", "--short", "HEAD")
    if not name:
        raise GoalError("a named branch is required")
    return name


def read_goal(slug, approved=True):
    directory = task_directory(slug)
    goal = load_json(directory / "goal.json")
    if type(goal.get("schemaVersion")) is not int or goal["schemaVersion"] != 1:
        raise GoalError("unsupported goal schemaVersion")
    if goal.get("taskID") != slug:
        raise GoalError("goal taskID does not match its directory")
    validate_spec(goal)
    strings(goal.get("changesAfterApproval", []), "changesAfterApproval")
    if goal.get("status") not in ("draft", "approved", "done"):
        raise GoalError("goal status must be draft, approved, or done")
    if goal.get("branch") != branch():
        raise GoalError("goal belongs to a different branch")
    base = goal.get("baseCommit")
    if not isinstance(base, str) or not re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", base):
        raise GoalError("goal baseCommit must be a full commit ID")
    if git("rev-parse", "--verify", f"{base}^{{commit}}") != base:
        raise GoalError("goal baseCommit is not a commit")
    try:
        content = (directory / "goal.md").read_text()
    except (OSError, UnicodeError) as error:
        raise GoalError(f"cannot read goal.md: {error}") from error
    if content != render_goal(goal):
        raise GoalError("goal.md does not match goal.json; create and approve a revised goal")
    if approved:
        if goal.get("status") not in ("approved", "done"):
            raise GoalError("goal requires explicit approval")
        if goal.get("approvedGoalSHA256") != digest(directory / "goal.md"):
            raise GoalError("goal changed after approval")
    return directory, goal


def current_snapshot(slug):
    directory, goal = read_goal(slug)
    if git("diff", "--name-only", "-z"):
        raise GoalError("unstaged changes exist; stage all delivery changes before verification")
    if git("ls-files", "--others", "--exclude-standard", "-z"):
        raise GoalError("untracked files exist; stage all delivery changes before verification")
    snapshot = {"schemaVersion": 1, "taskID": slug, "branch": goal["branch"],
                "baseCommit": goal["baseCommit"], "tree": git("write-tree"),
                "goalSHA256": digest(directory / "goal.md"),
                "goalManifestSHA256": digest(directory / "goal.json")}
    return directory, goal, snapshot


def validate_verdict(value, goal, snapshot, passing=False):
    if type(value.get("schemaVersion")) is not int or value["schemaVersion"] != 1:
        raise GoalError("unsupported verdict schemaVersion")
    if value.get("taskID") != goal["taskID"]:
        raise GoalError("verdict taskID does not match goal")
    provenance = value.get("provenance")
    if (not isinstance(provenance, dict) or type(provenance.get("schemaVersion")) is not int
            or provenance != snapshot):
        raise GoalError("verdict provenance does not match the current verification input")
    if value.get("verdict") not in ("pass", "fail"):
        raise GoalError("verdict must be pass or fail")
    criteria = value.get("criteria")
    if not isinstance(criteria, list) or len(criteria) != len(goal["criteria"]):
        raise GoalError("verdict criteria must match every goal criterion in order")
    failed = False
    for criterion, expected in zip(criteria, goal["criteria"]):
        if not isinstance(criterion, dict) or criterion.get("text") != expected["text"]:
            raise GoalError("verdict criteria must match every goal criterion in order")
        if type(criterion.get("pass")) is not bool:
            raise GoalError("criterion pass must be a boolean")
        strings(criterion.get("evidence"), "criterion evidence", nonempty=criterion["pass"])
        failed |= not criterion["pass"]
    issues = False
    for key in ("missing", "unexpected", "concerns"):
        issues |= bool(strings(value.get(key, []), key))
    if value["verdict"] == "pass" and (failed or issues):
        raise GoalError("passing verdict cannot contain failed criteria or unresolved issues")
    if passing and value["verdict"] != "pass":
        raise GoalError("delivery requires a passing verdict")


def init(args):
    directory = task_directory(args.slug)
    spec = load_json(Path(args.input))
    validate_spec(spec)
    goal = {"schemaVersion": 1, "taskID": args.slug, "branch": branch(),
            "baseCommit": git("rev-parse", "--verify", f"{args.base}^{{commit}}"),
            "request": spec["request"], "criteria": spec["criteria"],
            "outOfScope": spec["outOfScope"], "status": "draft"}
    # Artifacts must not become delivery changes themselves.
    ignored = subprocess.run(["git", "-C", str(REPOSITORY_ROOT), "check-ignore", "--quiet", str(directory / "goal.json")], check=False)
    if ignored.returncode != 0:
        raise GoalError(".claude/tasks must be gitignored before initializing a goal")
    try:
        directory.mkdir(parents=True, exist_ok=False)
    except FileExistsError as error:
        raise GoalError("task already exists; refusing to overwrite it") from error
    (directory / "goal.md").write_text(render_goal(goal))
    write_json(directory / "goal.json", goal)
    print(f"Created draft goal {args.slug}; explicit approval is required.")


def revise(args):
    directory, goal = read_goal(args.slug, approved=False)
    spec = load_json(Path(args.input))
    validate_spec(spec)
    reason = required_text(args.reason, "revision reason")
    history = directory / "history"
    if history.is_symlink():
        raise GoalError("task history must not be a symlink")
    revised = dict(goal)
    revised.update({"request": spec["request"], "criteria": spec["criteria"],
                    "outOfScope": spec["outOfScope"], "status": "draft",
                    "changesAfterApproval": [*goal.get("changesAfterApproval", []), reason]})
    revised.pop("approvedGoalSHA256", None)
    # Read every artifact before mutating anything; preserve exact bytes in the archive.
    artifacts = {}
    for name in ("goal.md", "goal.json", "verification-input.json", "verdict.json"):
        path = directory / name
        if path.exists():
            artifacts[name] = path.read_bytes()
    archive = history / str(uuid.uuid4())
    archive.mkdir(parents=True, exist_ok=False)
    for name, content in artifacts.items():
        (archive / name).write_bytes(content)
    (directory / "goal.md").write_text(render_goal(revised))
    write_json(directory / "goal.json", revised)
    for name in ("verification-input.json", "verdict.json"):
        path = directory / name
        if path.exists():
            path.unlink()
    print(f"Revised goal {args.slug}; approval and new verification are required. History: {archive.name}")


def approve(args):
    directory, goal = read_goal(args.slug, approved=False)
    if goal.get("status") != "draft" or "approvedGoalSHA256" in goal:
        raise GoalError("goal is already approved or not a draft")
    goal["approvedGoalSHA256"] = digest(directory / "goal.md")
    goal["status"] = "approved"
    write_json(directory / "goal.json", goal)
    print(f"Approved goal {args.slug}.")


def snapshot(args):
    directory, _, value = current_snapshot(args.slug)
    write_json(directory / "verification-input.json", value)
    print(json.dumps(value, indent=2))


def record(args):
    directory, goal, current = current_snapshot(args.slug)
    if load_json(directory / "verification-input.json") != current:
        raise GoalError("verification input is stale; capture a new snapshot and reverify")
    value = load_json(Path(args.input))
    validate_verdict(value, goal, current)
    write_json(directory / "verdict.json", value)
    print(f"Recorded {value['verdict']} verdict for {args.slug}.")


def find_task():
    current_branch = branch()
    root = Path(git("rev-parse", "--show-toplevel")) / ".claude" / "tasks"
    if root.is_symlink() or root.parent.is_symlink():
        raise GoalError("task directories must not be symlinks")
    matches = []
    if root.is_dir():
        for directory in sorted(root.iterdir()):
            if directory.is_dir():
                if directory.is_symlink() or (directory / "goal.json").is_symlink():
                    raise GoalError("task directories and goal manifests must not be symlinks")
                if not (directory / "goal.json").exists():
                    continue
                goal = load_json(directory / "goal.json")
                if goal.get("branch") == current_branch:
                    matches.append(directory.name)
    if len(matches) != 1:
        raise GoalError(f"expected exactly one task for branch {current_branch}; found {len(matches)}")
    return matches[0]


def check(args):
    slug = args.slug or find_task()
    directory, goal, current = current_snapshot(slug)
    if load_json(directory / "verification-input.json") != current:
        raise GoalError("verification input is stale; capture a new snapshot and reverify")
    validate_verdict(load_json(directory / "verdict.json"), goal, current, passing=True)
    print(f"Goal {slug} verified for tree {current['tree']}.")


def main():
    global REPOSITORY_ROOT
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("init", "revise", "approve", "snapshot", "record", "check"):
        command = commands.add_parser(name)
        command.add_argument("slug", nargs="?" if name == "check" else None)
        if name in ("init", "revise", "record"):
            command.add_argument("--input", required=True)
        if name == "revise":
            command.add_argument("--reason", required=True)
        if name == "init":
            command.add_argument("--base", default="origin/main")
    args = parser.parse_args()
    try:
        REPOSITORY_ROOT = Path(git("rev-parse", "--show-toplevel"))
        globals()[args.command](args)
    except (GoalError, OSError) as error:
        print(f"task-goal: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
