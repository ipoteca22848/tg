"""Prepare pinned Telegram Desktop sources and build a Windows x64 Debug EXE."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / ".build" / "tdesktop"
PIN = json.loads((ROOT / "upstream.json").read_text(encoding="utf-8"))


def run(args, cwd=ROOT, capture=False):
    command = [str(arg) for arg in args]
    if capture:
        return subprocess.run(command, cwd=cwd, check=True,
                              text=True, stdout=subprocess.PIPE).stdout
    started = time.monotonic()
    environment = os.environ.copy()
    environment["PYTHONUNBUFFERED"] = "1"
    with subprocess.Popen(command, cwd=cwd, env=environment) as process:
        while True:
            try:
                code = process.wait(timeout=45)
                if code:
                    raise subprocess.CalledProcessError(code, command)
                return None
            except subprocess.TimeoutExpired:
                minutes = (time.monotonic() - started) / 60
                print(f"Still running: {Path(command[0]).name}, {minutes:.1f} min elapsed. "
                      "This confirms the process is alive, not that compilation is progressing.",
                      flush=True)


def apply_patch(source, patch):
    reverse = subprocess.run(
        ["git", "apply", "--reverse", "--check", str(patch)], cwd=source,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if reverse.returncode == 0:
        return
    run(["git", "apply", "--check", patch], cwd=source)
    run(["git", "apply", patch], cwd=source)


def prepare(submodules=True):
    SOURCE.parent.mkdir(parents=True, exist_ok=True)
    if not SOURCE.exists():
        run(["git", "clone", "--depth", "1", "--branch", PIN["tag"],
             PIN["repository"], SOURCE])
    head = run(["git", "rev-parse", "HEAD"], cwd=SOURCE, capture=True).strip()
    if head != PIN["commit"]:
        raise RuntimeError("Source revision differs from upstream.json; preserving checkout.")
    for patch in sorted((ROOT / "patches").glob("*.patch")):
        apply_patch(SOURCE, patch)
    if submodules:
        run(["git", "submodule", "update", "--init", "--recursive", "--jobs", "4"],
            cwd=SOURCE)
    print(f"Prepared Telegram Desktop {PIN['tag']} ({head}).", flush=True)


def check_windows():
    if sys.platform != "win32":
        raise RuntimeError("EXE build requires native Windows and MSVC; use --prepare-only here.")
    if os.environ.get("Platform", "").lower() != "x64":
        raise RuntimeError("Use the x64 Native Tools Command Prompt with MSVC 14.44.")
    for command in ("git", "cmake", "cl", "ninja"):
        if not shutil.which(command):
            raise RuntimeError(f"Required tool is missing: {command}")


def credentials(test_api):
    if test_api:
        return
    if not re.fullmatch(r"[1-9][0-9]*", os.environ.get("TDESKTOP_API_ID", "")):
        raise RuntimeError("Set your own TDESKTOP_API_ID in the build environment.")
    if not re.fullmatch(r"[a-fA-F0-9]{32}", os.environ.get("TDESKTOP_API_HASH", "")):
        raise RuntimeError("Set TDESKTOP_API_HASH securely in the build environment.")


def verify_exe(path):
    with path.open("rb") as stream:
        if stream.read(2) != b"MZ":
            raise RuntimeError("Output is not a Windows executable.")
        stream.seek(0x3C)
        offset = stream.read(4)
        if len(offset) != 4:
            raise RuntimeError("Truncated Windows executable.")
        stream.seek(struct.unpack("<I", offset)[0])
        if stream.read(6) != b"PE\0\0\x64\x86":
            raise RuntimeError("Output is not an x64 PE executable.")


def package(test_api):
    exe = SOURCE / "out" / "Debug" / "Telegram.exe"
    verify_exe(exe)
    destination = ROOT / "dist"
    destination.mkdir(exist_ok=True)
    with exe.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    manifest = {
        "upstream": PIN, "configuration": "Debug", "architecture": "x64",
        "test_api_only": test_api, "exe_sha256": digest,
        "patches": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in sorted((ROOT / "patches").glob("*.patch"))},
        "runtime_validation": "NOT RUN: complete docs/validation.md on Windows",
    }
    suffix = "test-api" if test_api else "own-api"
    output = destination / f"tg-unofficial-windows-x64-debug-{suffix}.zip"
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.write(exe, "Telegram.exe")
        for filename in ("LICENSE", "LEGAL"):
            archive.write(SOURCE / filename, filename)
        archive.write(ROOT / "NOTICE.md", "NOTICE.md")
        archive.write(ROOT / "docs/validation.md", "VALIDATION.md")
        archive.writestr("BUILD.json", json.dumps(manifest, indent=2) + "\n")
    print(f"Built {output}. Runtime checks remain required.")


def build(test_api, jobs, stage="all"):
    check_windows()
    if stage in ("all", "configure"):
        credentials(test_api)
    if stage == "all":
        prepare()
    if stage in ("all", "dependencies"):
        print("Building dependencies: Qt, FFmpeg, WebRTC and others. First run can take hours.", flush=True)
        run([sys.executable, SOURCE / "Telegram/build/prepare/prepare.py",
             "skip-release", "silent", "qt6"], cwd=SOURCE)
    if stage in ("all", "configure"):
        configure(test_api)
    if stage in ("all", "compile"):
        print("Compiling Telegram Desktop Debug x64.", flush=True)
        run(["cmake", "--build", SOURCE / "out", "--config", "Debug",
             "--target", "Telegram", "--parallel", str(jobs)])
    if stage in ("all", "package"):
        package(test_api)


def configure(test_api):
    print("Configuring Telegram Desktop.", flush=True)
    initial_cache = SOURCE.parent / "api-cache.cmake"
    initial_cache.write_text(
        'set(TDESKTOP_API_ID "$ENV{TDESKTOP_API_ID}" CACHE STRING "API ID" FORCE)\n'
        'set(TDESKTOP_API_HASH "$ENV{TDESKTOP_API_HASH}" CACHE STRING "API hash" FORCE)\n',
        encoding="utf-8",
    )
    run([sys.executable, SOURCE / "Telegram/configure.py",
         "-G", "Ninja Multi-Config", "-C", initial_cache,
         "-D", f"TDESKTOP_API_TEST={'ON' if test_api else 'OFF'}",
         "-D", "CMAKE_CONFIGURATION_TYPES=Debug",
         "-D", "DESKTOP_APP_ENABLE_LTO=OFF",
         "-D", "DESKTOP_APP_DISABLE_AUTOUPDATE=ON"], cwd=SOURCE / "Telegram")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--no-submodules", action="store_true")
    parser.add_argument("--test-api", action="store_true",
                        help="Limited upstream test credentials; never distribute this build.")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--stage", choices=("all", "dependencies", "configure", "compile", "package"),
                        default="all", help="CI stages; prepare sources before running individual stages.")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if args.no_submodules and not args.prepare_only:
        parser.error("--no-submodules requires --prepare-only")
    try:
        if args.prepare_only:
            prepare(submodules=not args.no_submodules)
        else:
            build(args.test_api, args.jobs, args.stage)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
