"""Tests for transifex.py: uv run pytest"""

import pathlib
from collections.abc import Iterator
from typing import Any

import pytest

import transifex

Json = dict[str, Any]

DOWNLOADING = "Downloading %lld of %lld songs…"


def unit(value: str) -> Json:
    return {"stringUnit": {"state": "translated", "value": value}}


def plural(**forms: str) -> Json:
    return {"plural": {form: unit(value) for form, value in forms.items()}}


def catalog() -> Json:
    return {
        "sourceLanguage": "en",
        "version": "1.0",
        "strings": {
            "Settings": {"localizations": {"de": unit("Einstellungen")}},
            "%@ · port %lld": {},
            "%lld albums": {
                "localizations": {
                    "en": {"variations": plural(one="%lld album", other="%lld albums")}
                }
            },
            DOWNLOADING: {
                "localizations": {
                    "en": {
                        "stringUnit": {
                            "state": "translated",
                            "value": "Downloading %1$lld of %2$#@total@",
                        },
                        "substitutions": {
                            "total": {
                                "argNum": 2,
                                "formatSpecifier": "lld",
                                "variations": plural(
                                    one="%arg song…", other="%arg songs…"
                                ),
                            }
                        },
                    }
                }
            },
            "Clementine": {"shouldTranslate": False},
        },
    }


def translated(pluralized: bool = False, **forms: str) -> Json:
    return {"forms": forms, "pluralized": pluralized}


def test_merges_plain_and_plural_strings() -> None:
    ours = catalog()
    changed, rejected = transifex.merge(
        ours,
        "de",
        {
            "Settings": translated(other="Optionen"),
            "%@ · port %lld": translated(other="%@ · Port %lld"),
            "%lld albums": translated(True, one="%lld Album", other="%lld Alben"),
        },
    )
    assert (changed, rejected) == (3, [])
    strings = ours["strings"]
    assert strings["Settings"]["localizations"]["de"] == unit("Optionen")
    assert strings["%@ · port %lld"]["localizations"]["de"] == unit("%@ · Port %lld")
    assert strings["%lld albums"]["localizations"]["de"] == {
        "variations": plural(one="%lld Album", other="%lld Alben")
    }


def test_leaves_unchanged_translations_uncounted() -> None:
    ours = catalog()
    changed, _ = transifex.merge(
        ours, "de", {"Settings": translated(other="Einstellungen")}
    )
    assert changed == 0


def test_puts_substitutions_back_together() -> None:
    ours = catalog()
    changed, _ = transifex.merge(
        ours,
        "de",
        {
            DOWNLOADING: translated(other="Lade %1$lld von %2$#@total@"),
            f"{DOWNLOADING}.substitutions.total": translated(
                True, one="%arg Titel…", other="%arg Titeln…"
            ),
        },
    )
    assert changed == 1
    assert ours["strings"][DOWNLOADING]["localizations"]["de"] == {
        "stringUnit": {"state": "translated", "value": "Lade %1$lld von %2$#@total@"},
        "substitutions": {
            "total": {
                "argNum": 2,
                "formatSpecifier": "lld",
                "variations": plural(one="%arg Titel…", other="%arg Titeln…"),
            }
        },
    }


@pytest.mark.parametrize(
    "translations",
    [
        # Neither is translated: what made Transifex fail to make a file.
        {DOWNLOADING: None, f"{DOWNLOADING}.substitutions.total": None},
        # The string is, but its substitution isn't.
        {
            DOWNLOADING: translated(other="Lade %1$lld von %2$#@total@"),
            f"{DOWNLOADING}.substitutions.total": None,
        },
        # The substitution is missing altogether.
        {DOWNLOADING: translated(other="Lade %1$lld von %2$#@total@")},
        # A form is empty.
        {
            DOWNLOADING: translated(other="Lade %1$lld von %2$#@total@"),
            f"{DOWNLOADING}.substitutions.total": translated(
                True, one="", other="%arg Titeln…"
            ),
        },
    ],
)
def test_leaves_out_what_isnt_wholly_translated(
    translations: dict[str, Json | None],
) -> None:
    ours = catalog()
    assert transifex.merge(ours, "de", translations) == (0, [])
    assert "de" not in ours["strings"][DOWNLOADING]["localizations"]


def test_leaves_out_translations_with_the_wrong_placeholders() -> None:
    ours = catalog()
    changed, rejected = transifex.merge(
        ours,
        "de",
        {
            "%@ · port %lld": translated(other="%@ · Port"),
            # "one" may leave the number out, but no form may add another.
            "%lld albums": translated(True, one="Ein Album", other="%lld %@ Alben"),
            DOWNLOADING: translated(other="Lade %1$lld von %2$#@total@"),
            f"{DOWNLOADING}.substitutions.total": translated(
                True, one="%arg Titel %@", other="%arg Titeln…"
            ),
        },
    )
    assert changed == 0
    assert sorted(rejected) == sorted(["%@ · port %lld", "%lld albums", DOWNLOADING])


def test_a_plurals_one_can_leave_the_number_out() -> None:
    ours = catalog()
    changed, rejected = transifex.merge(
        ours,
        "de",
        {"%lld albums": translated(True, one="Ein Album", other="%lld Alben")},
    )
    assert (changed, rejected) == (1, [])


def test_skips_strings_not_to_translate_and_the_source_language() -> None:
    ours = catalog()
    assert transifex.merge(
        ours, "de", {"Clementine": translated(other="Klementine")}
    ) == (0, [])
    assert transifex.merge(ours, "en", {"Settings": translated(other="Options")}) == (
        0,
        [],
    )
    assert "localizations" not in ours["strings"]["Clementine"]


def test_ignores_strings_the_app_doesnt_have() -> None:
    ours = catalog()
    assert transifex.merge(ours, "de", {"Gone": translated(other="Weg")}) == (0, [])
    assert "Gone" not in ours["strings"]


def test_locale() -> None:
    assert transifex.locale("pt_BR") == "pt-BR"
    assert transifex.locale("sr@latin") == "sr-Latn"
    assert transifex.locale("de") == "de"


def test_reads_translations_across_pages(monkeypatch: pytest.MonkeyPatch) -> None:
    def string(n: int, key: str, pluralized: bool) -> Json:
        return {"id": f"s{n}", "attributes": {"key": key, "pluralized": pluralized}}

    def translation(n: int, strings: Json | None) -> Json:
        return {
            "attributes": {"strings": strings},
            "relationships": {"resource_string": {"data": {"id": f"s{n}"}}},
        }

    pages = [
        {
            "data": [translation(1, {"other": "Optionen"}), translation(2, None)],
            "included": [
                string(1, "Settings", False),
                string(2, "Untranslated", False),
            ],
        },
        {
            "data": [
                translation(3, {"one": "%lld Album", "other": "%lld Alben"}),
                translation(4, {"other": "Fertig."}),
            ],
            "included": [
                string(3, "%lld albums", True),
                string(4, "Done\\.", False),
            ],
        },
    ]

    def fake_pages(
        _: transifex.Transifex, url: str, params: dict[str, str]
    ) -> Iterator[Json]:
        assert url == "/resource_translations"
        assert params["filter[language]"] == "l:de"
        yield from pages

    monkeypatch.setattr(transifex.Transifex, "pages", fake_pages)
    assert transifex.Transifex("token").translations("de") == {
        "Settings": translated(other="Optionen"),
        "Untranslated": None,
        "%lld albums": translated(True, one="%lld Album", other="%lld Alben"),
        "Done.": translated(other="Fertig."),
    }


def test_writes_the_catalog_as_xcode_does(tmp_path: pathlib.Path) -> None:
    path = tmp_path / "Localizable.xcstrings"
    transifex.write_catalog(
        path, {"strings": {"b": {}, "a": {"x": 1}}, "version": "1.0"}
    )
    assert path.read_text() == (
        '{\n  "strings" : {\n    "a" : {\n      "x" : 1\n    },\n'
        '    "b" : {\n\n    }\n  },\n  "version" : "1.0"\n}'
    )
