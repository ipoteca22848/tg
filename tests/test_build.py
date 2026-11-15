import importlib.util
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "build", Path(__file__).resolve().parents[1] / "scripts/build.py")
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)


class BuildSafetyTests(unittest.TestCase):
    def test_rejects_non_windows_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "Telegram.exe"
            for contents in (b"", b"#!/bin/sh\n", b"MZ", b"\x7fELF" + bytes(100)):
                output.write_bytes(contents)
                with self.assertRaises(RuntimeError):
                    build.verify_exe(output)

    def test_rejects_wrong_architecture(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "Telegram.exe"
            header = bytearray(128)
            header[:2] = b"MZ"
            header[0x3C:0x40] = struct.pack("<I", 64)
            header[64:70] = b"PE\0\0\x4c\x01"
            output.write_bytes(header)
            with self.assertRaises(RuntimeError):
                build.verify_exe(output)
            header[68:70] = b"\x64\x86"
            output.write_bytes(header)
            build.verify_exe(output)

    def test_patch_repeatability_and_conflict_preserves_file(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            target = source / "example.txt"
            target.write_text("original\n")
            patchfile = source / "change.patch"
            patchfile.write_text(
                "diff --git a/example.txt b/example.txt\n"
                "--- a/example.txt\n+++ b/example.txt\n"
                "@@ -1 +1 @@\n-original\n+modified\n")
            build.apply_patch(source, patchfile)
            build.apply_patch(source, patchfile)
            self.assertEqual(target.read_text(), "modified\n")
            target.write_text("user change\n")
            with self.assertRaises(subprocess.CalledProcessError):
                build.apply_patch(source, patchfile)
            self.assertEqual(target.read_text(), "user change\n")

    def test_missing_credentials_fail_without_echoing_values(self):
        with patch.dict(build.os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "TDESKTOP_API_ID"):
                build.credentials(False)
            build.credentials(True)

    def test_linux_build_stops_before_downloads(self):
        with patch.object(build.sys, "platform", "linux"):
            with patch.object(build, "prepare") as prepare:
                with self.assertRaisesRegex(RuntimeError, "native Windows"):
                    build.build(True, 4)
                prepare.assert_not_called()

    def test_command_failure_preserves_exit_status(self):
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            build.run([build.sys.executable, "-c", "raise SystemExit(7)"])
        self.assertEqual(caught.exception.returncode, 7)

    def test_compile_stage_does_not_rebuild_dependencies(self):
        with patch.object(build, "check_windows"), patch.object(build, "run") as run:
            with patch.object(build, "prepare") as prepare, patch.object(build, "package") as package:
                build.build(True, 2, "compile")
                prepare.assert_not_called()
                package.assert_not_called()
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0][0:2], ["cmake", "--build"])


if __name__ == "__main__":
    unittest.main()
