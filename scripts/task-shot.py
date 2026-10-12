#!/usr/bin/env python3
"""Register an inspected PNG in a task's versioned screenshot manifest."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def atomic_write(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink()
            raise
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def valid_entry(entry):
    if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
        return False
    path = entry["path"]
    parts = path.split("/")
    return (len(parts) >= 2 and parts[0] == "shots"
            and all(part not in ("", ".", "..") for part in parts)
            and not any(character in path for character in ("\\", "%", "\0"))
            and isinstance(entry.get("caption"), str)
            and entry.get("appearance") in (None, "light", "dark")
            and (entry.get("criterion") is None or isinstance(entry["criterion"], str)))


def validate_png(data):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("screenshot must be a PNG")
    # Force ImageIO to decode the captured bytes, rather than trusting the file header.
    with tempfile.TemporaryDirectory(prefix="task-shot-") as scratch:
        source = Path(scratch) / "source.png"
        decoded = Path(scratch) / "decoded.png"
        source.write_bytes(data)
        result = subprocess.run(
            ["/usr/bin/sips", "-s", "format", "png", str(source), "--out", str(decoded)],
            capture_output=True, check=False)
        if result.returncode != 0 or not decoded.is_file():
            raise ValueError("screenshot PNG cannot be decoded")


def register(task_id, image, caption, task_root, appearance=None, criterion=None):
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", task_id):
        raise ValueError("task ID must be a lowercase kebab slug")
    image = Path(image)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.png", image.name):
        raise ValueError("screenshot filename must be a simple .png filename")
    data = image.read_bytes()
    validate_png(data)
    directory = Path(task_root).resolve() / task_id
    directory.mkdir(parents=True, exist_ok=True)
    if directory.is_symlink():
        raise ValueError("task directory must not be a symlink")
    shots = directory / "shots"
    if shots.is_symlink():
        raise ValueError("shots directory must not be a symlink")
    shots.mkdir(exist_ok=True)
    # Serialize re-captures and parallel verify runs; publish the image before its entry.
    lock_path = directory / ".shots.lock"
    if lock_path.is_symlink():
        raise ValueError("lock file must not be a symlink")
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manifest_path = directory / "shots.json"
        manifest = {"schemaVersion": 1, "taskID": task_id, "screenshots": []}
        if manifest_path.exists():
            manifest = json.loads(manifest_path.read_text())
            if (not isinstance(manifest, dict) or type(manifest.get("schemaVersion")) is not int
                    or manifest.get("schemaVersion") != 1 or manifest.get("taskID") != task_id
                    or not isinstance(manifest.get("screenshots"), list)):
                raise ValueError("existing manifest has an unsupported version, task ID, or shape")
            if not all(valid_entry(entry) for entry in manifest["screenshots"]):
                raise ValueError("existing screenshot entries have invalid paths or metadata")
        entry = {"path": f"shots/{image.name}", "caption": caption}
        if appearance:
            entry["appearance"] = appearance
        if criterion:
            entry["criterion"] = criterion
        entries = manifest["screenshots"]
        for index, previous in enumerate(entries):
            if previous["path"] == entry["path"]:
                entries[index] = entry
                break
        else:
            entries.append(entry)
        atomic_write(shots / image.name, data)
        atomic_write(manifest_path, (json.dumps(manifest, indent=2) + "\n").encode())
    return directory / entry["path"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("task_id")
    parser.add_argument("image", type=Path)
    parser.add_argument("caption")
    parser.add_argument("--task-root", type=Path, default=Path(".claude/tasks"))
    parser.add_argument("--appearance", choices=("light", "dark"))
    parser.add_argument("--criterion")
    arguments = parser.parse_args()
    try:
        output = register(arguments.task_id, arguments.image, arguments.caption,
                          arguments.task_root, arguments.appearance, arguments.criterion)
    except (OSError, ValueError) as error:
        parser.exit(1, f"task-shot: {error}\n")
    print(output)


if __name__ == "__main__":
    main()
