#!/usr/bin/env python3
"""Check ordinary gh pr create invocations in Claude's Bash hook."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys


def creations(command, cwd):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>")
    lexer.whitespace_split = True
    lexer.commenters = "#"
    chunks = []
    current = []
    for token in lexer:
        if token and all(character in ";&|()<>" for character in token):
            if current:
                chunks.append(current)
                current = []
        else:
            current.append(token)
    if current:
        chunks.append(current)
    if not any("pr" in chunk and "create" in chunk
               and any(Path(token).name == "gh" for token in chunk) for chunk in chunks):
        return
    directory = Path(cwd)
    for tokens in chunks:
        while tokens and "=" in tokens[0] and tokens[0].split("=", 1)[0].isidentifier():
            tokens = tokens[1:]
        if tokens and tokens[0] == "builtin":
            tokens = tokens[1:]
        if tokens and tokens[0] == "command":
            tokens = tokens[1:]
            if tokens and tokens[0] in ("-v", "-V"):
                continue  # command lookup does not execute the supplied names
            if tokens and tokens[0] in ("-p", "--"):
                tokens = tokens[1:]
        if tokens and tokens[0] == "exec":
            tokens = tokens[1:]
            while tokens and tokens[0].startswith("-"):
                option = tokens[0]
                if option == "-a" and len(tokens) >= 2:
                    tokens = tokens[2:]
                elif option in ("-c", "-l", "-cl", "-lc"):
                    tokens = tokens[1:]
                elif option == "--":
                    tokens = tokens[1:]
                    break
                else:
                    raise ValueError("unsupported exec option before PR creation")
        if tokens and Path(tokens[0]).name == "env":
            tokens = tokens[1:]
            while tokens:
                option = tokens[0]
                if option in ("-i", "--ignore-environment", "-", "-0", "--null", "-v", "--debug"):
                    tokens = tokens[1:]
                elif option in ("-u", "--unset", "-C", "--chdir"):
                    if len(tokens) < 2:
                        raise ValueError("env option needs an argument")
                    if option in ("-C", "--chdir"):
                        if "$" in tokens[1] or "`" in tokens[1]:
                            raise ValueError("use a literal worktree path for env --chdir")
                        directory = (directory / tokens[1]).resolve()
                    tokens = tokens[2:]
                elif option.startswith("--unset="):
                    tokens = tokens[1:]
                elif option.startswith("--chdir="):
                    path = option.split("=", 1)[1]
                    if "$" in path or "`" in path:
                        raise ValueError("use a literal worktree path for env --chdir")
                    directory = (directory / path).resolve()
                    tokens = tokens[1:]
                elif option == "--":
                    tokens = tokens[1:]
                    break
                elif "=" in option and option.split("=", 1)[0].isidentifier():
                    tokens = tokens[1:]
                elif option.startswith("-"):
                    raise ValueError("unsupported env option before PR creation; run the goal check explicitly")
                else:
                    break
            while tokens and "=" in tokens[0] and tokens[0].split("=", 1)[0].isidentifier():
                tokens = tokens[1:]
        if not tokens:
            continue
        if tokens[0] == "cd":
            args = tokens[1:]
            if args and args[0] == "--":
                args = args[1:]
            if len(args) != 1 or "$" in args[0] or "`" in args[0]:
                raise ValueError("use a literal worktree path for cd before PR creation")
            directory = (directory / os.path.expanduser(args[0])).resolve()
        elif Path(tokens[0]).name == "gh":
            args = tokens[1:]
            while args and args[0].startswith("-"):
                option = args.pop(0)
                if option in ("--repo", "-R") and args:
                    args.pop(0)
                elif option.startswith("--repo="):
                    continue
                else:
                    break
            if args[:2] == ["pr", "create"]:
                yield directory


def main():
    try:
        event = json.load(sys.stdin)
        command = event.get("tool_input", {}).get("command", "")
        cwd = event.get("cwd", os.getcwd())
        for directory in creations(command, cwd):
            result = subprocess.run(
                ["git", "-C", str(directory), "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, check=False)
            if result.returncode:
                raise ValueError("PR creation must run from the implementation worktree")
            root = Path(result.stdout.strip())
            checked = subprocess.run(
                ["python3", str(root / "scripts/task-goal.py"), "check"], cwd=root, check=False)
            if checked.returncode:
                return 2
    except (OSError, ValueError, TypeError, AttributeError) as error:
        print(f"Goal gate: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
