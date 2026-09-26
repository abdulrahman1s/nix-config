"""Check that AI plans cannot replace files or escape the selected folder."""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parent.parent / "file-sorter.py"
spec = importlib.util.spec_from_file_location("file_sorter", SOURCE)
assert spec is not None and spec.loader is not None
sorter = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = sorter
spec.loader.exec_module(sorter)


class FileSorterTests(unittest.TestCase):
    def test_model_receives_names_only_on_loopback(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "project-notes.txt").write_text("PRIVATE_FILE_BODY_CANARY")
            files, _ = sorter.scan(folder)
            content = json.dumps({"assignments": [{"id": 0, "folder": "Project Notes"}]})
            response = io.BytesIO(json.dumps({"choices": [{"message": {"content": content}}]}).encode())
            with patch.object(sorter, "LOCAL_URL", "http://127.0.0.1:11434/v1"), patch.object(sorter, "urlopen", return_value=response) as open_mock:
                moves = sorter.classify(files)
            self.assertEqual(moves[0].folder_name, "Project Notes")
            request = json.loads(open_mock.call_args.args[0].data)
            self.assertEqual(request["model"], "local")
            self.assertIn("project-notes.txt", json.dumps(request))
            self.assertNotIn("PRIVATE_FILE_BODY_CANARY", json.dumps(request))

    def test_scan_ignores_unfinished_hidden_links_and_folders(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "report.pdf").write_text("report")
            (folder / "pending.crdownload").write_text("partial")
            (folder / ".hidden").write_text("private")
            (folder / "Existing").mkdir()
            (folder / "linked.pdf").symlink_to(folder / "report.pdf")
            files, omitted = sorter.scan(folder)
            self.assertEqual([file.path.name for file in files], ["report.pdf"])
            self.assertEqual(omitted, 0)

    def test_model_plan_requires_safe_flat_shared_folders(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for index in range(9):
                (folder / f"file-{index}.txt").write_text("x")
            files, _ = sorter.scan(folder)

            def plan(names):
                return json.dumps({"assignments": [{"id": index, "folder": name} for index, name in enumerate(names)]})

            self.assertEqual([move.folder_name for move in sorter.parse_plan(plan(["Project Notes"] * 9), files)], ["Project Notes"] * 9)
            for bad in ("../Elsewhere", "A/B", ".hidden", "Trailing ", "a\nb"):
                with self.assertRaises(RuntimeError):
                    sorter.parse_plan(plan([bad] * 9), files)
            with self.assertRaises(RuntimeError):
                sorter.parse_plan(plan([f"Topic {index}" for index in range(9)]), files)
            with self.assertRaises(RuntimeError):
                sorter.parse_plan(plan(["Notes", "notes"] + ["Notes"] * 7), files)

    def test_moves_preserve_conflicts_and_changed_files(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            source = folder / "report.txt"
            source.write_text("new")
            candidate = sorter.scan(folder)[0][0]
            destination_dir = folder / "Reports"
            destination_dir.mkdir()
            (destination_dir / source.name).write_text("existing")
            self.assertEqual(sorter.apply_moves([sorter.Move(candidate, "Reports")], folder), (0, 1))
            self.assertEqual((destination_dir / source.name).read_text(), "existing")
            self.assertEqual(source.read_text(), "new")

            source.write_text("changed after preview")
            self.assertEqual(sorter.apply_moves([sorter.Move(candidate, "Fresh")], folder), (0, 1))
            self.assertFalse((folder / "Fresh" / source.name).exists())

            fresh = sorter.scan(folder)[0][0]
            self.assertEqual(sorter.apply_moves([sorter.Move(fresh, "Fresh")], folder), (1, 0))
            self.assertFalse(source.exists())
            self.assertEqual((folder / "Fresh" / source.name).read_text(), "changed after preview")

    def test_category_symlink_does_not_redirect_moves(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as elsewhere:
            folder = Path(directory)
            (folder / "notes.txt").write_text("notes")
            (folder / "Notes").symlink_to(elsewhere, target_is_directory=True)
            candidate = sorter.scan(folder)[0][0]
            self.assertEqual(sorter.apply_moves([sorter.Move(candidate, "Notes")], folder), (0, 1))
            self.assertTrue((folder / "notes.txt").exists())
            self.assertFalse((Path(elsewhere) / "notes.txt").exists())


if __name__ == "__main__":
    unittest.main()
