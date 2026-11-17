"""Tests for sentry_symbols.py: uv run pytest"""

import json
import pathlib
import plistlib

import pytest

import sentry_symbols
from sentry_symbols import DebugFile

APP_ID = "11111111-1111-1111-1111-111111111111"
WIDGET_ID = "22222222-2222-2222-2222-222222222222"


def check_output(debug_ids: list[str], features: str, usable: bool = True) -> str:
    return json.dumps(
        {
            "type": "macho",
            "file_format": "macho",
            "arch": "arm64",
            "is_usable": usable,
            "features": features,
            "variants": [{"debug_id": i, "arch": "arm64"} for i in debug_ids],
        }
    )


def test_reads_what_sentry_cli_says() -> None:
    dsym = sentry_symbols.parse_check("a", check_output([APP_ID], "symtab, debug"))
    assert dsym == DebugFile("a", frozenset([APP_ID]), has_debug_info=True)
    stripped = sentry_symbols.parse_check("b", check_output([APP_ID], "symtab"))
    assert not stripped.has_debug_info
    unusable = sentry_symbols.parse_check(
        "c", check_output([APP_ID], "debug", usable=False)
    )
    assert not unusable.has_debug_info


def test_each_executable_needs_a_dsym_with_debug_info() -> None:
    app = DebugFile("app", frozenset([APP_ID]), has_debug_info=False)
    widget = DebugFile("widget", frozenset([WIDGET_ID]), has_debug_info=False)
    app_dsym = DebugFile("app.dSYM", frozenset([APP_ID]), has_debug_info=True)
    widget_dsym = DebugFile("widget.dSYM", frozenset([WIDGET_ID]), has_debug_info=True)
    assert sentry_symbols.missing_symbols([app, widget], [app_dsym, widget_dsym]) == []
    assert sentry_symbols.missing_symbols([app, widget], [app_dsym]) == [
        f"widget: no dSYM for {WIDGET_ID}"
    ]
    stripped = DebugFile("widget.dSYM", frozenset([WIDGET_ID]), has_debug_info=False)
    assert sentry_symbols.missing_symbols([widget], [stripped]) == [
        f"widget: no dSYM for {WIDGET_ID}"
    ]
    nameless = DebugFile("tool", frozenset(), has_debug_info=False)
    assert sentry_symbols.missing_symbols([nameless], []) == ["tool has no debug ID"]


def bundle(path: pathlib.Path, executable: str) -> None:
    path.mkdir(parents=True)
    with (path / "Info.plist").open("wb") as f:
        plistlib.dump({"CFBundleExecutable": executable}, f)


def test_finds_the_app_and_its_extensions(tmp_path: pathlib.Path) -> None:
    app = tmp_path / "Products" / "Applications" / "Clementine Remote.app"
    bundle(app, "Clementine Remote")
    bundle(app / "PlugIns" / "ClementineWidget.appex", "ClementineWidget")
    assert sentry_symbols.bundle_executables(tmp_path) == [
        app / "Clementine Remote",
        app / "PlugIns" / "ClementineWidget.appex" / "ClementineWidget",
    ]


def test_uploads_nothing_without_a_token(
    tmp_path: pathlib.Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.delenv("SENTRY_AUTH_TOKEN", raising=False)
    monkeypatch.setenv("SENTRY_PROJECT", "clementine-remote-ios")
    assert sentry_symbols.upload(tmp_path) == 0
    assert "no SENTRY_AUTH_TOKEN" in capsys.readouterr().out
