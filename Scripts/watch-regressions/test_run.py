"""Failure-path checks for the host runner; no Swift build or network required."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True  # keep __pycache__ out of the tree


spec = importlib.util.spec_from_file_location("watch_runner", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.build = Path(self.folder.name)

    def make_build(self):
        (self.build / "Modules").mkdir()
        objects = []
        for target in runner.MANIFEST["core_targets"]:
            directory = self.build / f"{target}.build"
            directory.mkdir()
            obj = directory / "source.swift.o"
            obj.touch()
            objects.append(str(obj))
            (directory / "output-file-map.json").write_text(json.dumps({
                "source.swift": {"object": str(obj)},
            }))
            (self.build / "Modules" / f"{target}.swiftmodule").touch()
        return objects

    def test_absent_build_fails_with_rebuild_instruction(self):
        with self.assertRaisesRegex(RuntimeError, "Core debug build is absent.*swift build"):
            runner.core_objects(self.build)

    def test_empty_target_fails_instead_of_linking_nothing(self):
        self.make_build()
        (self.build / "WatchPlayback.build/output-file-map.json").write_text("{}")
        with self.assertRaisesRegex(RuntimeError, "WatchPlayback produced no objects"):
            runner.core_objects(self.build)

    def test_missing_object_and_module_fail_with_target_name(self):
        objects = self.make_build()
        Path(objects[0]).unlink()
        with self.assertRaisesRegex(RuntimeError, "WatchPlayback is missing object"):
            runner.core_objects(self.build)
        Path(objects[0]).touch()
        (self.build / "Modules/WatchPlayback.swiftmodule").unlink()
        with self.assertRaisesRegex(RuntimeError, "WatchPlayback is missing its module"):
            runner.core_objects(self.build)

    def test_swift_build_layout_links_one_object_per_target(self):
        expected = []
        for target in runner.MANIFEST["core_targets"]:
            (self.build / f"{target}.o").touch()
            (self.build / f"{target}.swiftmodule").mkdir()
            expected.append(str(self.build / f"{target}.o"))
        self.assertEqual(runner.core_objects(self.build), expected)
        self.assertEqual(runner.core_module_directory(self.build), self.build)
        (self.build / "WatchPlayback.o").unlink()
        with self.assertRaisesRegex(RuntimeError, "WatchPlayback is missing object"):
            runner.core_objects(self.build)

    def test_manifest_excludes_stale_objects(self):
        expected = self.make_build()
        (self.build / "WatchPlayback.build/deleted.swift.o").touch()
        self.assertEqual(runner.core_objects(self.build), expected)

    def test_build_path_lookup_and_fallback(self):
        result = subprocess.CompletedProcess([], 0, stdout=str(self.build) + "\n")
        with patch.object(runner.subprocess, "run", return_value=result) as run:
            self.assertEqual(runner.core_build_directory({}), self.build.resolve())
            self.assertIn("--show-bin-path", run.call_args.args[0])
            self.assertEqual(run.call_args.kwargs["timeout"], 120)
        with patch.object(runner.subprocess, "run", side_effect=OSError("lookup unavailable")):
            self.assertEqual(runner.core_build_directory({}),
                             runner.CORE / ".build/arm64-apple-macosx/debug")

    def test_timeout_and_nonzero_failure_name_program(self):
        failures = (
            (subprocess.TimeoutExpired(["probe"], 120), "Probe: timed out after 120 s"),
            (subprocess.CalledProcessError(7, ["probe"]), "Probe: failed with exit code 7"),
            (OSError("missing"), "Probe: could not start: missing"),
        )
        for failure, message in failures:
            with self.subTest(failure=failure):
                with patch.object(runner.subprocess, "run", side_effect=failure):
                    with self.assertRaisesRegex(RuntimeError, message):
                        runner.run_step("Probe", ["probe"], {})

    def test_cache_directories_and_environment_reach_every_step(self):
        calls = []
        def record_step(name, command, env):
            calls.append(env)
        with patch.object(runner, "CORE", self.build), \
             patch.object(runner, "core_build_directory", return_value=self.build) as locate, \
             patch.object(runner, "core_objects", return_value=[]), \
             patch.object(runner, "program_sources", return_value=[]), \
             patch.object(runner, "run_step", side_effect=record_step):
            self.assertEqual(runner.main(), 0)
        calls.append(locate.call_args.args[0])
        self.assertEqual(len(calls), 2 + 2 * len(runner.MANIFEST["programs"]))
        for env in calls:
            for key, leaf in (("CLANG_MODULE_CACHE_PATH", "mcache"), ("XDG_CACHE_HOME", "xdg")):
                self.assertEqual(env[key], str(self.build / ".build" / leaf))
                self.assertTrue(Path(env[key]).is_dir())


if __name__ == "__main__":
    unittest.main()
