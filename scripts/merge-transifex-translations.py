#!/usr/bin/env python3
"""Merges translations pulled from Transifex into App/Resources/Localizable.xcstrings.

    scripts/merge-transifex-translations.py build/transifex/*.xcstrings

Each pulled file is a String Catalog, with translations in one language or several. Their
translated strings replace the app catalog's, for the strings the app has (Xcode decides
which those are, not Transifex). A translation whose placeholders don't match the English, which
would show the wrong thing or crash, is left out. Translations are only added or changed, never
removed. Run by .github/workflows/translations.yml after `tx pull`.
"""

import collections
import json
import pathlib
import re
import sys

CATALOG = pathlib.Path(__file__).resolve().parent.parent / "App/Resources/Localizable.xcstrings"
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])")


def placeholders(text):
    """The kinds of placeholder in a string, counted: "%1$@ and %lld" -> {"@": 1, "d": 1}."""
    return collections.Counter(PLACEHOLDER.findall(text.replace("%%", "")))


def units(localization):
    """Every stringUnit in a localization, through its variations."""
    if "stringUnit" in localization:
        yield localization["stringUnit"]
    for variation in localization.get("variations", {}).values():
        for form in variation.values():
            yield from units(form)


def locale(code):
    """Transifex's language code as Apple's: pt_BR -> pt-BR, sr@latin -> sr-Latn."""
    return code.replace("@latin", "-Latn").replace("@cyrillic", "-Cyrl").replace("_", "-")


def acceptable(localization, source):
    """Whether a pulled translation is whole, and has the English's placeholders."""
    found = list(units(localization))
    if not found or any(unit.get("state") != "translated" or not unit.get("value") for unit in found):
        return False
    if "variations" in localization:
        # A plural's "one" can say "One song" rather than "%lld song".
        return all(not placeholders(unit["value"]) - source for unit in found)
    return placeholders(found[0]["value"]) == source


def main(paths):
    catalog = json.loads(CATALOG.read_text())
    source_language = catalog["sourceLanguage"]
    changed, rejected = collections.Counter(), []
    for path in paths:
        pulled = json.loads(pathlib.Path(path).read_text())
        for key, entry in pulled.get("strings", {}).items():
            if key not in catalog["strings"] or catalog["strings"][key].get("shouldTranslate") is False:
                continue
            ours = catalog["strings"][key]
            english = ours.get("localizations", {}).get(source_language, {})
            # The English's placeholders: its "other" form for a plural.
            english_units = list(units(english))
            source = placeholders(english_units[-1]["value"] if english_units else key)
            for code, localization in entry.get("localizations", {}).items():
                language = locale(code)
                if language == source_language:
                    continue
                if not acceptable(localization, source):
                    if any(unit.get("state") == "translated" for unit in units(localization)):
                        rejected.append(f"{language}: {key!r}")
                    continue
                localizations = ours.setdefault("localizations", {})
                if localizations.get(language) != localization:
                    localizations[language] = localization
                    changed[language] += 1

    CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
    for problem in sorted(set(rejected)):
        print(f"::warning::Left out a translation whose placeholders don't match the English: {problem}")
    print(f"{sum(changed.values())} translations changed" +
          (": " + ", ".join(f"{language} {n}" for language, n in sorted(changed.items())) if changed else "."))


if __name__ == "__main__":
    main(sys.argv[1:])
