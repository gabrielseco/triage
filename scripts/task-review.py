#!/usr/bin/env python3
"""Capture revision-bound review inputs and publish complete structured reviews."""

import argparse
import importlib.util
from pathlib import Path
import re
import sys


SPEC = importlib.util.spec_from_file_location("task_goal", Path(__file__).with_name("task-goal.py"))
goal = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(goal)


def review_paths(directory, source):
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", source):
        raise goal.GoalError("review source must be a lowercase kebab slug")
    paths = [directory / name / f"{source}.json" for name in ("review-inputs", "reviews")]
    for path in paths:
        if path.parent.is_symlink() or path.is_symlink():
            raise goal.GoalError("review directories and artifacts must not be symlinks")
    return paths


def context(task_id, source, base, head=None):
    directory, _, value = goal.current_snapshot(task_id)
    review_paths(directory, source)
    value.update(source=source, baseCommit=goal.git("rev-parse", "--verify", f"{base}^{{commit}}"))
    if head is not None:
        value["headCommit"] = goal.git("rev-parse", "--verify", f"{head}^{{commit}}")
        if goal.git("rev-parse", f"{value['headCommit']}^{{tree}}") != value["tree"]:
            raise goal.GoalError("review head commit does not match the staged tree")
    return directory, value


def validate_review(value, expected):
    if type(value.get("schemaVersion")) is not int or value["schemaVersion"] != 1:
        raise goal.GoalError("unsupported review schemaVersion")
    if value.get("taskID") != expected["taskID"] or value.get("source") != expected["source"]:
        raise goal.GoalError("review taskID and source must match the snapshot")
    if value.get("status") != "complete":
        raise goal.GoalError("only complete reviews can be published")
    provenance = value.get("provenance")
    if (not isinstance(provenance, dict) or type(provenance.get("schemaVersion")) is not int
            or provenance != expected):
        raise goal.GoalError("review provenance does not match the current review input")
    findings = value.get("findings")
    if not isinstance(findings, list):
        raise goal.GoalError("review findings must be an array")
    for finding in findings:
        if not isinstance(finding, dict):
            raise goal.GoalError("each finding must be an object")
        if finding.get("severity") not in ("blocking", "warning", "suggestion"):
            raise goal.GoalError("unsupported finding severity")
        goal.required_text(finding.get("message"), "finding message")
        if "file" in finding:
            file = goal.required_text(finding["file"], "finding file")
            if (file.startswith("/") or "\\" in file or "\0" in file
                    or any(part in ("", ".", "..") for part in file.split("/"))):
                raise goal.GoalError("finding file must be a repository-relative path without traversal")
        if "line" in finding:
            if type(finding["line"]) is not int or finding["line"] < 1 or "file" not in finding:
                raise goal.GoalError("finding line must be a positive integer with a file")
        if "evidence" in finding:
            goal.strings(finding["evidence"], "finding evidence")


def snapshot(args):
    directory, value = context(args.task_id, args.source, args.base, args.head)
    path, _ = review_paths(directory, args.source)
    path.parent.mkdir(exist_ok=True)
    goal.write_json(path, value)
    print(f"Captured {args.source} input for {args.task_id}, tree {value['tree']}.")


def record(args):
    directory = goal.task_directory(args.task_id)
    snapshot_path, output_path = review_paths(directory, args.source)
    stored = goal.load_json(snapshot_path)
    base = goal.required_text(stored.get("baseCommit"), "review input baseCommit")
    head = stored.get("headCommit")
    if "headCommit" in stored:
        goal.required_text(head, "review input headCommit")
    _, current = context(args.task_id, args.source, base, head)
    if type(stored.get("schemaVersion")) is not int or stored != current:
        raise goal.GoalError("review input is stale; capture a new snapshot and review again")
    input_path = Path(args.input)
    if input_path.is_symlink():
        raise goal.GoalError("review input must not be a symlink")
    value = goal.load_json(input_path)
    validate_review(value, current)
    output_path.parent.mkdir(exist_ok=True)
    goal.write_json(output_path, value)
    print(f"Recorded complete {args.source} review for {args.task_id}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("snapshot", "record"):
        command = commands.add_parser(name)
        command.add_argument("task_id")
        command.add_argument("source")
        if name == "snapshot":
            command.add_argument("--base", default="origin/main")
            command.add_argument("--head")
        else:
            command.add_argument("--input", required=True)
    args = parser.parse_args()
    try:
        goal.REPOSITORY_ROOT = Path(goal.git("rev-parse", "--show-toplevel"))
        globals()[args.command](args)
    except (goal.GoalError, OSError) as error:
        print(f"task-review: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
