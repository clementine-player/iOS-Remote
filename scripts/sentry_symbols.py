#!/usr/bin/env -S uv run --only-group sentry
"""Checks an archive's dSYMs, and uploads them to Sentry for its crash reports.

    uv run --only-group sentry scripts/sentry_symbols.py ARCHIVE

Run by .github/workflows/testflight.yml and release.yml, on the archive
scripts/archive.sh makes. Crash reports for the app's Sentry project are
addresses, not function names: Sentry turns them into names and lines with the
dSYMs, matched to the app's executables by debug ID (their Mach-O UUIDs).

It fails unless every executable in the archive, the app's and the widget's, has
a dSYM with debug info and its debug IDs, so a build can't quietly stop making
them. Then it uploads the dSYMs, with their sources, with sentry-cli's
SENTRY_AUTH_TOKEN, SENTRY_ORG and SENTRY_PROJECT; Sentry skips files it has
already. Without a token or a project it only says so, so that builds without the
repository's secrets still pass.
"""

import argparse
import json
import os
import pathlib
import plistlib
import subprocess
import sys
from collections.abc import Iterable
from dataclasses import dataclass


@dataclass(frozen=True)
class DebugFile:
    """What sentry-cli says about one file."""

    path: str
    debug_ids: frozenset[str]
    has_debug_info: bool


def parse_check(path: str, output: str) -> DebugFile:
    """Reads `sentry-cli debug-files check --json` output for a file."""
    data = json.loads(output)
    features = {f.strip() for f in (data.get("features") or "").split(",")}
    return DebugFile(
        path=path,
        debug_ids=frozenset(v["debug_id"] for v in data.get("variants", [])),
        has_debug_info=bool(data.get("is_usable")) and "debug" in features,
    )


def check_file(path: pathlib.Path) -> DebugFile | None:
    """Asks sentry-cli about a file, or None if it isn't a debug file."""
    result = subprocess.run(
        ["sentry-cli", "debug-files", "check", "--json", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return parse_check(str(path), result.stdout)


def missing_symbols(
    executables: Iterable[DebugFile], symbols: Iterable[DebugFile]
) -> list[str]:
    """The problems with symbols for executables, or none if each has them."""
    with_debug_info: set[str] = set()
    for symbol in symbols:
        if symbol.has_debug_info:
            with_debug_info |= symbol.debug_ids
    problems = []
    for executable in executables:
        if not executable.debug_ids:
            problems.append(f"{executable.path} has no debug ID")
        for debug_id in sorted(executable.debug_ids - with_debug_info):
            problems.append(f"{executable.path}: no dSYM for {debug_id}")
    return problems


def bundle_executables(archive: pathlib.Path) -> list[pathlib.Path]:
    """The executables of the archive's app and of the extensions in it."""
    bundles: list[pathlib.Path] = []
    for app in sorted((archive / "Products" / "Applications").glob("*.app")):
        bundles.append(app)
        bundles += sorted((app / "PlugIns").glob("*.appex"))
    executables = []
    for bundle in bundles:
        with (bundle / "Info.plist").open("rb") as f:
            info = plistlib.load(f)
        executables.append(bundle / info["CFBundleExecutable"])
    return executables


def check(archive: pathlib.Path) -> int:
    paths = bundle_executables(archive)
    if not paths:
        print(f"::error::{archive} has no app in it")
        return 1
    executables = []
    for path in paths:
        executable = check_file(path)
        if executable is None:
            print(f"::error::{path} isn't something Sentry can read")
            return 1
        executables.append(executable)
    symbols = [
        f
        for f in map(check_file, sorted((archive / "dSYMs").rglob("*")))
        if f and f.debug_ids
    ]
    for symbol in symbols:
        kind = "debug info" if symbol.has_debug_info else "no debug info"
        print(f"{symbol.path}: {', '.join(sorted(symbol.debug_ids))} ({kind})")
    problems = missing_symbols(executables, symbols)
    for problem in problems:
        print(f"::error::{problem}")
    return 1 if problems else 0


def upload(archive: pathlib.Path) -> int:
    missing = [
        name
        for name in ("SENTRY_AUTH_TOKEN", "SENTRY_PROJECT")
        if not os.environ.get(name)
    ]
    if missing:
        print(
            "::notice::Not uploading debug symbols to Sentry: no "
            f"{' or '.join(missing)}."
        )
        return 0
    return subprocess.run(
        [
            "sentry-cli",
            "debug-files",
            "upload",
            "--include-sources",
            str(archive / "dSYMs"),
        ],
        check=False,
    ).returncode


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("archive", type=pathlib.Path)
    args = parser.parse_args(argv)
    return check(args.archive) or upload(args.archive)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
