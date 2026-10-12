#!/usr/bin/env python3
"""Observe GitHub PR lifecycle facts and append revision-bound task events."""

import argparse
from datetime import datetime
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import stat
import sys
import uuid


SPEC = importlib.util.spec_from_file_location("task_goal", Path(__file__).with_name("task-goal.py"))
goal = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(goal)


def require(condition, message):
    if not condition:
        raise goal.GoalError(message)


def commit(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", value),
            "head must be a full commit ID")
    return value


def timestamp(value):
    goal.required_text(value, "timestamp")
    require(re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})", value),
            "timestamp must be ISO 8601 with a timezone")
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise goal.GoalError("invalid timestamp") from error
    return value


def gh(*args):
    result = subprocess.run(["gh", *args], capture_output=True, text=True, check=False)
    require(result.returncode == 0, f"GitHub observation failed: {result.stderr.strip()}")
    try:
        value = json.loads(result.stdout)
    except ValueError as error:
        raise goal.GoalError("GitHub returned invalid JSON") from error
    require(isinstance(value, dict), "GitHub observation must be an object")
    return value


def repository():
    origin = goal.git("remote", "get-url", "origin")
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([\w.-]+/[\w.-]+?)(?:\.git)?/?", origin)
    require(match is not None, "origin must identify a GitHub repository")
    expected = match[1]
    repo = gh("repo", "view", expected, "--json", "nameWithOwner").get("nameWithOwner")
    require(isinstance(repo, str) and repo.lower() == expected.lower(),
            "GitHub repository does not match origin")
    return repo


def positive(value, label):
    require(type(value) is int and value > 0, f"{label} must be a positive integer")
    return str(value)


def observed_pr(repo, number, branch):
    pr = gh("api", f"repos/{repo}/pulls/{number}")
    require(pr.get("number") == number and type(pr.get("number")) is int, "PR number mismatch")
    for side in ("base", "head"):
        info = pr.get(side)
        require(isinstance(info, dict) and isinstance(info.get("repo"), dict)
                and info["repo"].get("full_name") == repo, "PR repository mismatch")
    require(pr["head"].get("ref") == branch, "PR branch does not match the approved task")
    commit(pr["head"].get("sha"))
    require(pr.get("html_url") == f"https://github.com/{repo}/pull/{number}", "PR URL mismatch")
    timestamp(pr.get("created_at"))
    return pr


def event(task, kind, identity, when, payload):
    return {"schemaVersion": 1, "taskID": task,
            "id": str(uuid.uuid5(uuid.NAMESPACE_URL, json.dumps([task, kind, *identity], separators=(",", ":")))),
            "timestamp": timestamp(when), "kind": kind, "payload": payload}


def records(content, task):
    require(not content or content.endswith(b"\n"), "event log has an incomplete trailing record")
    try:
        lines = content.decode("utf-8").splitlines()
    except UnicodeError as error:
        raise goal.GoalError("event log is not UTF-8") from error
    result = []
    identifiers = set()
    for line in lines:
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except ValueError as error:
            raise goal.GoalError("event log contains malformed JSON") from error
        require(isinstance(value, dict), "event record must be an object")
        require(type(value.get("schemaVersion")) is int and value["schemaVersion"] == 1,
                "unsupported event schemaVersion")
        require(value.get("taskID") == task, "event taskID mismatch")
        try:
            uuid.UUID(value["id"])
        except (KeyError, ValueError, TypeError, AttributeError) as error:
            raise goal.GoalError("event id must be a UUID") from error
        require(value["id"] not in identifiers, "event log contains duplicate IDs")
        identifiers.add(value["id"])
        timestamp(value.get("timestamp"))
        goal.required_text(value.get("kind"), "event kind")
        payload = value.get("payload")
        require(isinstance(payload, dict) and all(isinstance(key, str) and isinstance(item, str)
                                                for key, item in payload.items()),
                "event payload must contain only strings")
        result.append(value)
    return result


def opened(path, flags):
    require(not path.is_symlink(), f"event paths must not be symlinks: {path.name}")
    descriptor = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise goal.GoalError("event paths must be regular files")
    return descriptor


def publish(args):
    commit(args.head)
    directory, approved = goal.read_goal(args.task)
    lock_path, log_path = directory / ".events.lock", directory / "events.jsonl"
    require(not log_path.is_symlink(), "event log must not be a symlink")
    with os.fdopen(opened(lock_path, os.O_CREAT | os.O_RDWR), "r+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        # Recheck the goal under the shared lock, before observing remote facts.
        directory, approved = goal.read_goal(args.task)
        require(not log_path.is_symlink(), "event log must not be a symlink")
        content = b""
        if log_path.exists():
            with os.fdopen(opened(log_path, os.O_RDONLY), "rb") as source:
                content = source.read()
        history = records(content, args.task)
        repo = repository()
        pr = observed_pr(repo, args.pr, approved["branch"])
        common = {"repo": repo, "url": pr["html_url"], "number": str(args.pr),
                  "headCommit": args.head, "branch": approved["branch"]}
        creation_identity = [repo, str(args.pr)]
        creation = event(args.task, "pr.created", creation_identity, pr["created_at"],
                         {**common, "createdAt": pr["created_at"]})
        attached = [item for item in history if item["kind"] == "pr.created"]
        require(len(attached) <= 1, "task contains conflicting PR attachments")
        if attached:
            previous = attached[0]
            require(previous["id"] == creation["id"], "task is already attached to a different PR")
            expected = {key: value for key, value in creation["payload"].items() if key != "headCommit"}
            require(all(previous["payload"].get(key) == value for key, value in expected.items())
                    and previous["timestamp"] == creation["timestamp"], "PR creation facts contradict history")
            commit(previous["payload"].get("headCommit"))
            if args.command == "pr-created":
                print("PR creation already recorded; preserved its original revision.")
                return
        else:
            require(args.command == "pr-created", "record PR creation before CI or merge observations")
        require(goal.git("rev-parse", "HEAD") == args.head, "requested head does not match the worktree HEAD")
        require(pr["head"]["sha"] == args.head, "requested head does not match the observed PR head")
        if args.command == "pr-created":
            value = creation
        elif args.command == "pr-merged":
            timestamp(pr.get("merged_at"))
            merge = commit(pr.get("merge_commit_sha"))
            value = event(args.task, "pr.merged", creation_identity, pr["merged_at"],
                          {**common, "mergedAt": pr["merged_at"], "mergeCommit": merge})
        else:
            run = gh("api", f"repos/{repo}/actions/runs/{args.run}")
            require(type(run.get("id")) is int and run["id"] == args.run, "CI run ID mismatch")
            require(isinstance(run.get("repository"), dict)
                    and run["repository"].get("full_name") == repo, "CI repository mismatch")
            require(run.get("head_sha") == args.head and run.get("head_branch") == approved["branch"],
                    "CI revision or branch mismatch")
            links = run.get("pull_requests")
            require(isinstance(links, list), "CI PR associations must be an array")
            if links:
                require(any(isinstance(item, dict) and type(item.get("number")) is int
                            and item["number"] == args.pr for item in links),
                        "CI run is not associated with the requested PR")
            else:
                # GitHub can omit associations even on pull_request runs. Repository,
                # branch and exact currently observed PR revision already match above.
                require(run.get("event") in ("push", "pull_request"),
                        "CI run without PR associations must be a push or pull_request event")
            attempt = positive(run.get("run_attempt"), "run attempt")
            require(run.get("status") in ("queued", "in_progress", "completed", "waiting", "requested", "pending"),
                    "unsupported CI run status")
            if run["status"] != "completed" or run.get("conclusion") is None:
                print("CI run has no terminal conclusion; no event recorded.")
                return
            conclusion = run["conclusion"]
            require(conclusion in ("success", "failure", "neutral", "cancelled", "skipped", "timed_out",
                                   "action_required", "stale", "startup_failure"), "unsupported CI conclusion")
            url = run.get("html_url")
            require(url == f"https://github.com/{repo}/actions/runs/{args.run}", "CI URL mismatch")
            value = event(args.task, "ci.completed", [repo, str(args.run), attempt, args.head], run.get("updated_at"),
                          {**common, "url": url, "runID": str(args.run), "runAttempt": attempt, "status": conclusion})
        for previous in history:
            if value["kind"] == "ci.completed" and previous["kind"] == "ci.completed":
                keys = ("repo", "runID", "runAttempt")
                if all(previous["payload"].get(key) == value["payload"][key] for key in keys):
                    require(previous["payload"].get("headCommit") == args.head,
                            "CI attempt revision contradicts immutable history")
            if previous["id"] == value["id"]:
                require(previous["kind"] == value["kind"] and previous["payload"] == value["payload"]
                        and previous["timestamp"] == value["timestamp"], "event facts contradict immutable history")
                print("Event already recorded.")
                return
        encoded = (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        with os.fdopen(opened(log_path, os.O_CREAT | os.O_WRONLY | os.O_APPEND), "ab") as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        print(f"Recorded {value['kind']} for {args.task}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("pr-created", "ci-completed", "pr-merged"):
        command = commands.add_parser(name)
        command.add_argument("task")
        command.add_argument("--pr", type=int, required=True)
        command.add_argument("--head", required=True)
        if name == "ci-completed":
            command.add_argument("--run", type=int, required=True)
    args = parser.parse_args()
    try:
        positive(args.pr, "PR number")
        if args.command == "ci-completed":
            positive(args.run, "run ID")
        goal.REPOSITORY_ROOT = Path(goal.git("rev-parse", "--show-toplevel"))
        publish(args)
    except (goal.GoalError, OSError, UnicodeError) as error:
        print(f"task-event: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
