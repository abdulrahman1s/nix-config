"""Regression checks for kernel scheduling and remembered build failures."""

import importlib.util
import json
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "nix_cache", Path(__file__).with_name("nix-cache.py")
)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)

KERNEL = "/nix/store/kernel-linux.drv"
KERNEL_OUT = f"{KERNEL}^out"
MODULE = "/nix/store/module-wireview.drv^out"
OTHER = "/nix/store/other-package.drv^out"


class KernelBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        for name in (
            "BUILT_PATHS",
            "EVALUATION_PATHS",
            "UPLOADED_PATHS",
            "NEXT_FAILURES",
        ):
            replacement = Path(temporary.name) / name
            patcher = patch.object(cache, name, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(cache, "log")
        patcher.start()
        self.addCleanup(patcher.stop)
        self.stats = cache.Stats()

    def test_kernel_finishes_before_parallel_packages(self):
        kernel_ready = threading.Event()
        workers = threading.Barrier(2)
        calls = []

        def build(target, kernel):
            calls.append(target)
            if target == KERNEL_OUT:
                kernel_ready.set()
            else:
                self.assertTrue(kernel_ready.is_set())
                workers.wait(timeout=5)
            return target, 0

        with patch.object(cache, "build_one", side_effect=build):
            cache.build_packages([MODULE, OTHER, KERNEL_OUT], KERNEL, self.stats)
        self.assertEqual(calls[0], KERNEL_OUT)
        self.assertCountEqual(calls, [KERNEL_OUT, MODULE, OTHER])
        self.assertEqual((self.stats.attempted, self.stats.succeeded), (3, 3))
        self.assertEqual(cache.read_lines(cache.NEXT_FAILURES), set())

    def test_kernel_failure_defers_packages_without_remembering_them(self):
        with patch.object(cache, "build_one", return_value=(KERNEL_OUT, 124)) as build:
            cache.build_packages([MODULE, KERNEL_OUT, OTHER], KERNEL, self.stats)
        build.assert_called_once_with(KERNEL_OUT, KERNEL)
        self.assertEqual((self.stats.attempted, self.stats.failed), (1, 1))
        self.assertEqual(cache.read_lines(cache.NEXT_FAILURES), {KERNEL_OUT})

    def test_skipped_kernel_cannot_be_restarted_by_package_workers(self):
        cache.write_lines(cache.NEXT_FAILURES, {KERNEL_OUT, OTHER})
        with patch.object(cache, "build_one") as build:
            cache.build_packages([MODULE], KERNEL, self.stats)
        build.assert_not_called()
        self.assertEqual((self.stats.attempted, self.stats.failed), (0, 2))
        self.assertEqual(cache.read_lines(cache.NEXT_FAILURES), {KERNEL_OUT, OTHER})

    def test_cached_kernel_allows_modules_and_preserves_other_failures(self):
        cache.write_lines(cache.NEXT_FAILURES, {OTHER})
        with patch.object(cache, "build_one", return_value=(MODULE, 0)) as build:
            cache.build_packages([MODULE], KERNEL, self.stats)
        build.assert_called_once_with(MODULE, KERNEL)
        self.assertEqual((self.stats.succeeded, self.stats.failed), (1, 1))
        self.assertEqual(cache.read_lines(cache.NEXT_FAILURES), {OTHER})

    def test_multiple_kernel_outputs_are_built_together_once(self):
        with patch.object(cache, "build_one", return_value=(KERNEL_OUT, 0)) as build:
            cache.build_packages([KERNEL_OUT, f"{KERNEL}^dev"], KERNEL, self.stats)
        build.assert_called_once_with(KERNEL_OUT, KERNEL)
        self.assertEqual((self.stats.attempted, self.stats.succeeded), (2, 2))

    def test_module_failure_is_remembered(self):
        with patch.object(cache, "build_one", return_value=(MODULE, 1)):
            cache.build_packages([MODULE], KERNEL, self.stats)
        self.assertEqual(cache.read_lines(cache.NEXT_FAILURES), {MODULE})
        self.assertEqual((self.stats.attempted, self.stats.failed), (1, 1))

    def test_no_targets_keeps_failure_count(self):
        cache.write_lines(cache.NEXT_FAILURES, {KERNEL_OUT})
        with patch.object(cache, "build_one") as build:
            cache.build_packages([], KERNEL, self.stats)
        build.assert_not_called()
        self.assertEqual((self.stats.attempted, self.stats.failed), (0, 1))

    def test_kernel_command_builds_all_outputs_with_full_cpu_budget(self):
        with patch.object(
            cache.subprocess, "run", return_value=SimpleNamespace(returncode=0)
        ) as run:
            self.assertEqual(cache.build_one(KERNEL_OUT, KERNEL), (KERNEL_OUT, 0))
        command = run.call_args.args[0]
        self.assertEqual(command[-1], f"{KERNEL}^*")
        self.assertEqual(command[command.index("--kill-after=2m") + 1], "270m")
        self.assertEqual(command[command.index("cores") + 1], "0")
        self.assertEqual(command[command.index("max-jobs") + 1], "1")

    def test_module_command_keeps_its_shorter_limit(self):
        with patch.object(
            cache.subprocess, "run", return_value=SimpleNamespace(returncode=124)
        ) as run:
            self.assertEqual(cache.build_one(MODULE, KERNEL), (MODULE, 124))
        command = run.call_args.args[0]
        self.assertEqual(command[-1], MODULE)
        self.assertEqual(command[command.index("--kill-after=2m") + 1], "45m")
        self.assertEqual(command[command.index("cores") + 1], "2")

    def test_retry_input_requeues_remembered_failures(self):
        evaluation = {
            "system": "/nix/store/system.drv",
            "kernel": KERNEL,
            "packages": [
                {"target": target, "path": target.split(".", 1)[0]}
                for target in (KERNEL_OUT, MODULE)
            ],
        }
        client = SimpleNamespace(
            read=lambda key: (200, f"{KERNEL_OUT}\n{MODULE}\n".encode())
        )
        plan = "\n".join(
            f"  {target.split('^')[0]}" for target in (KERNEL_OUT, MODULE)
        )
        for retry in ("false", "true"):
            with (
                self.subTest(retry=retry),
                patch.dict(cache.os.environ, {"RETRY_FAILED": retry}),
                patch.object(cache, "snapshot_built_records", return_value=[]),
                patch.object(
                    cache.subprocess,
                    "run",
                    side_effect=[
                        subprocess.CompletedProcess([], 0, json.dumps(evaluation)),
                        subprocess.CompletedProcess([], 0, plan),
                    ],
                ),
            ):
                targets, *_ = cache.evaluate_targets(client, self.stats)
            expected = {KERNEL_OUT, MODULE} if retry == "true" else set()
            self.assertEqual(set(targets), expected)
            self.assertEqual(
                cache.read_lines(cache.NEXT_FAILURES), {KERNEL_OUT, MODULE} - expected
            )


if __name__ == "__main__":
    unittest.main()
