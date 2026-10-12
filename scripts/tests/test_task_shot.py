import importlib.util
import base64
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "task_shot", Path(__file__).resolve().parents[1] / "task-shot.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class TaskShotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tasks = self.root / "tasks"
        self.image = self.root / "inbox.png"
        self.image.write_bytes(base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg=="))

    def register(self, **options):
        return MODULE.register("sample-task", self.image, "Inbox", self.tasks, **options)

    def manifest(self):
        return self.tasks / "sample-task" / "shots.json"

    def test_capture_and_recapture_preserve_other_entries_and_unknown_fields(self):
        output = self.register(appearance="light", criterion="Usable inbox")
        self.assertEqual(output.read_bytes(), self.image.read_bytes())
        manifest = json.loads(self.manifest().read_text())
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["taskID"], "sample-task")
        self.assertEqual(manifest["screenshots"][0]["criterion"], "Usable inbox")
        manifest["extension"] = "preserved"
        manifest["screenshots"].append({"path": "shots/other.png", "caption": "Other"})
        self.manifest().write_text(json.dumps(manifest))
        self.register(appearance="dark")
        updated = json.loads(self.manifest().read_text())
        self.assertEqual(updated["extension"], "preserved")
        self.assertEqual(len(updated["screenshots"]), 2)
        self.assertEqual(updated["screenshots"][0]["appearance"], "dark")
        self.assertNotIn("criterion", updated["screenshots"][0])
        self.assertEqual(updated["screenshots"][1], manifest["screenshots"][1])

    def test_rejects_incompatible_or_malformed_manifest_without_overwriting(self):
        self.register()
        for content in ['{', '[]', '{"schemaVersion": 2}',
                        '{"schemaVersion": 1, "taskID": "other", "screenshots": []}',
                        '{"schemaVersion": 1, "taskID": "sample-task", "screenshots": [3]}']:
            with self.subTest(content=content):
                self.manifest().write_text(content)
                with self.assertRaises(ValueError):
                    self.register()
                self.assertEqual(self.manifest().read_text(), content)

    def test_rejects_task_traversal_and_non_png(self):
        with self.assertRaises(ValueError):
            MODULE.register("../escape", self.image, "Inbox", self.tasks)
        self.image.write_bytes(b"not a PNG")
        with self.assertRaises(ValueError):
            self.register()
        self.assertFalse(self.tasks.exists())

    def test_rejects_truncated_png_before_creating_artifacts(self):
        self.image.write_bytes(b"\x89PNG\r\n\x1a\n")
        with self.assertRaises(ValueError):
            self.register()
        self.assertFalse(self.tasks.exists())

    def test_rejects_symlinked_output_directory(self):
        directory = self.tasks / "sample-task"
        directory.mkdir(parents=True)
        outside = self.root / "outside"
        outside.mkdir()
        (directory / "shots").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.register()
        self.assertEqual(list(outside.iterdir()), [])

    def test_invalid_existing_entry_does_not_get_republished(self):
        self.register()
        for entry in ({"path": "shots/../escape.png", "caption": "Escape"},
                      {"path": "shots/other.png"},
                      {"path": "shots/other.png", "caption": "Other", "appearance": "sepia"}):
            with self.subTest(entry=entry):
                content = json.dumps({"schemaVersion": 1, "taskID": "sample-task",
                                      "screenshots": [entry]})
                self.manifest().write_text(content)
                with self.assertRaises(ValueError):
                    self.register()
                self.assertEqual(self.manifest().read_text(), content)


if __name__ == "__main__":
    unittest.main()
