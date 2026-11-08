#!/usr/bin/env -S uv run
"""Sends the String Catalog to Transifex, and merges Transifex's translations into it.

    uv run scripts/transifex.py pull
    uv run scripts/transifex.py push-source
    uv run scripts/transifex.py push-translations

Run by .github/workflows/translations.yml, with a Transifex API token in TX_TOKEN.

pull asks Transifex's API for each language's translations as data, rather than for
translated files: Transifex fails to make a String Catalog file while a string with
substitutions (a plural of one of a string's numbers) isn't translated. Each catalog
entry is put together from them here, a string's substitutions included, which
Transifex keeps as strings of their own, "<key>.substitutions.<name>". Translated
strings come back whether they're reviewed or not. A translation replaces the
catalog's, for the strings the app has (Xcode decides which those are, not
Transifex); one whose placeholders don't match the English, which would show the wrong
thing or crash, is left out. Translations are only added or changed, never removed.

push-source uploads the catalog as the resource's source. Transifex takes the
catalog's translations along with its strings, replacing its own, so the workflow
pulls first. push-translations uploads the catalog as one language's translations,
which Transifex takes for every language in it.
"""

import argparse
import collections
import json
import os
import pathlib
import re
import sys
import time
from collections.abc import Iterator
from typing import Any

import requests

Json = dict[str, Any]

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "App/Resources/Localizable.xcstrings"
# https://app.transifex.com/davidsansome/clementine-remot/, next to the Android remote.
PROJECT = "o:davidsansome:p:clementine-remot"
RESOURCE = f"{PROJECT}:r:ios"
API = "https://rest.api.transifex.com"
PLACEHOLDER = re.compile(
    r"%(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?"
    r"(?:hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])"
)


class TransifexError(Exception):
    """Transifex refused a request, or failed to process an upload."""


class Transifex:
    """Transifex's API, with the token in TX_TOKEN."""

    def __init__(self, token: str) -> None:
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {token}"

    def get(self, url: str, params: dict[str, str] | None = None) -> Json:
        response = self.session.get(
            url if url.startswith("https:") else API + url,
            params=params,
            headers={"Accept": "application/vnd.api+json"},
            timeout=60,
        )
        check(response)
        return response.json()

    def pages(self, url: str, params: dict[str, str]) -> Iterator[Json]:
        """Each page of a list, following its "next" links."""
        page = self.get(url, params)
        yield page
        while page.get("links", {}).get("next"):
            page = self.get(page["links"]["next"])
            yield page

    def languages(self) -> list[str]:
        """The project's languages, as Transifex's codes: pt_BR, sr@latin."""
        page = self.get(f"/projects/{PROJECT}/languages")
        return sorted(language["attributes"]["code"] for language in page["data"])

    def keys(self) -> set[str]:
        """The keys of the resource's strings, as the catalog's."""
        params = {"filter[resource]": RESOURCE, "limit": "1000"}
        return {
            unescape(string["attributes"]["key"])
            for page in self.pages("/resource_strings", params)
            for string in page["data"]
        }

    def translations(self, language: str) -> dict[str, Json | None]:
        """A language's translations, by their string's key: the translation's plural
        forms, {"other": ...} for a string that isn't a plural, or None when the string
        isn't translated. A pluralized string's forms come with "pluralized": True.
        The keys are the catalog's (see unescape)."""
        params = {
            "filter[resource]": RESOURCE,
            "filter[language]": f"l:{language}",
            "include": "resource_string",
            "limit": "1000",
        }
        found: dict[str, Json | None] = {}
        for page in self.pages("/resource_translations", params):
            strings = {s["id"]: s["attributes"] for s in page.get("included", [])}
            for translation in page["data"]:
                source = strings[
                    translation["relationships"]["resource_string"]["data"]["id"]
                ]
                forms = translation["attributes"]["strings"]
                found[unescape(source["key"])] = (
                    {"forms": forms, "pluralized": source["pluralized"]}
                    if forms
                    else None
                )
        return found

    def upload(self, kind: str, path: pathlib.Path, **fields: str) -> Json:
        """Uploads a file (kind: resource_strings or resource_translations), and waits
        for Transifex to process it."""
        response = self.session.post(
            f"{API}/{kind}_async_uploads",
            data={"resource": RESOURCE, **fields},
            files={"content": (path.name, path.read_bytes())},
            timeout=120,
        )
        check(response)
        upload = response.json()["data"]
        for _ in range(120):
            attributes = upload["attributes"]
            if attributes["status"] == "succeeded":
                return attributes.get("details") or {}
            if attributes["status"] == "failed":
                raise TransifexError(json.dumps(attributes.get("errors"), indent=2))
            time.sleep(2)
            upload = self.get(f"/{kind}_async_uploads/{upload['id']}")["data"]
        raise TransifexError(
            "Transifex didn't finish processing the upload in 4 minutes"
        )


def unescape(key: str) -> str:
    """A Transifex string's key as the catalog's: Transifex writes a "." in a key as
    "\\.", since it puts the parts of a key together with "."."""
    return key.replace("\\.", ".")


def check(response: requests.Response) -> None:
    """Raises Transifex's errors when it refused a request."""
    if response.ok:
        return
    try:
        errors = response.json().get("errors")
    except ValueError:
        errors = response.text
    raise TransifexError(
        f"{response.request.method} {response.url}: {response.status_code}\n"
        + json.dumps(errors, indent=2, ensure_ascii=False)
    )


def placeholders(text: str) -> collections.Counter[str]:
    """The kinds of placeholder in a string, counted:
    "%1$@ and %lld" -> {"@": 1, "d": 1}."""
    return collections.Counter(PLACEHOLDER.findall(text.replace("%%", "")))


def units(localization: Json) -> Iterator[Json]:
    """Every stringUnit in a localization, through its variations and substitutions."""
    if "stringUnit" in localization:
        yield localization["stringUnit"]
    for variation in localization.get("variations", {}).values():
        for form in variation.values():
            yield from units(form)
    for substitution in localization.get("substitutions", {}).values():
        yield from units(substitution)


def locale(code: str) -> str:
    """Transifex's language code as Apple's: pt_BR -> pt-BR, sr@latin -> sr-Latn."""
    return (
        code.replace("@latin", "-Latn").replace("@cyrillic", "-Cyrl").replace("_", "-")
    )


def unit(value: str) -> Json:
    return {"stringUnit": {"state": "translated", "value": value}}


def plural(forms: dict[str, str]) -> Json:
    return {"plural": {form: unit(value) for form, value in forms.items()}}


def localization(
    key: str, english: Json, translations: dict[str, Json | None]
) -> Json | None:
    """A catalog entry's localization in one language, made from Transifex's
    translations of its string and of each of its English's substitutions. None if
    any of them isn't translated."""
    translation = translations.get(key)
    if translation is None:
        return None
    forms = translation["forms"]
    made = (
        {"variations": plural(forms)}
        if translation["pluralized"]
        else unit(forms.get("other", ""))
    )
    for name, substitution in english.get("substitutions", {}).items():
        part = translations.get(f"{key}.substitutions.{name}")
        if part is None:
            return None
        made.setdefault("substitutions", {})[name] = {
            "argNum": substitution["argNum"],
            "formatSpecifier": substitution["formatSpecifier"],
            "variations": plural(part["forms"]),
        }
    if not all(found["value"] for found in units(made)):
        return None
    return made


def source_placeholders(english: Json, key: str) -> collections.Counter[str]:
    """The English's placeholders, outside its substitutions: its "other" form for a
    plural, or the key when the English is the key."""
    if "stringUnit" in english:
        return placeholders(english["stringUnit"]["value"])
    if "variations" in english:
        return placeholders(
            english["variations"]["plural"]["other"]["stringUnit"]["value"]
        )
    return placeholders(key)


def acceptable(made: Json, english: Json, key: str) -> bool:
    """Whether a translation has the English's placeholders. A plural's "one" can say
    "One song" rather than "%lld song", so each plural form needs only no others."""
    source = source_placeholders(english, key)
    if "stringUnit" in made and placeholders(made["stringUnit"]["value"]) != source:
        return False
    for variations in made.get("variations", {}).values():
        if any(
            placeholders(form["stringUnit"]["value"]) - source
            for form in variations.values()
        ):
            return False
    for name, substitution in made.get("substitutions", {}).items():
        theirs = english["substitutions"][name]["variations"]["plural"]
        allowed = placeholders(theirs["other"]["stringUnit"]["value"])
        for form in substitution["variations"]["plural"].values():
            if placeholders(form["stringUnit"]["value"]) - allowed:
                return False
    return True


def merge(
    catalog: Json, language: str, translations: dict[str, Json | None]
) -> tuple[int, list[str]]:
    """Merges one language's translations into the catalog. Returns how many changed,
    and the keys of those left out for their placeholders."""
    source_language = catalog["sourceLanguage"]
    if language == source_language:
        return 0, []
    changed, rejected = 0, []
    for key, entry in catalog["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        english = entry.get("localizations", {}).get(source_language, {})
        made = localization(key, english, translations)
        if made is None:
            continue
        if not acceptable(made, english, key):
            rejected.append(key)
            continue
        localizations = entry.setdefault("localizations", {})
        if localizations.get(language) != made:
            localizations[language] = made
            changed += 1
    return changed, rejected


def write_catalog(path: pathlib.Path, catalog: Json) -> None:
    """Writes the catalog as Xcode does, so that a build doesn't rewrite it: " : "
    between keys and values, keys sorted, an empty object over three lines, and no
    newline at the end."""
    text = json.dumps(
        catalog, indent=2, ensure_ascii=False, separators=(",", " : "), sort_keys=True
    )
    text = re.sub(
        r"^( *)(.* : )\{\}(,?)$",
        lambda m: f"{m.group(1)}{m.group(2)}{{\n\n{m.group(1)}}}{m.group(3)}",
        text,
        flags=re.MULTILINE,
    )
    path.write_text(text, encoding="utf-8")


def pull(transifex: Transifex) -> None:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    changed: dict[str, int] = {}
    # Strings added since the last push, until the next one sends them.
    missing = catalog["strings"].keys() - transifex.keys()
    for code in transifex.languages():
        language = locale(code)
        translations = transifex.translations(code)
        count, rejected = merge(catalog, language, translations)
        if count:
            changed[language] = count
        for key in rejected:
            print(
                "::warning::Left out a translation whose placeholders don't match "
                f"the English: {language}: {key!r}"
            )
    write_catalog(CATALOG, catalog)
    if missing:
        print(f"{len(missing)} of the catalog's strings aren't on Transifex:")
        for key in sorted(missing):
            print(f"  {key!r}")
    total = sum(changed.values())
    print(
        f"{total} translations changed"
        + (
            ": " + ", ".join(f"{lang} {n}" for lang, n in sorted(changed.items()))
            if changed
            else "."
        )
    )


def push_source(transifex: Transifex) -> None:
    details = transifex.upload("resource_strings", CATALOG)
    print(f"Pushed the strings: {json.dumps(details)}")


def push_translations(transifex: Transifex) -> None:
    # The catalog has every language, and Transifex takes them all from a file uploaded
    # as any one of them.
    details = transifex.upload(
        "resource_translations", CATALOG, language="l:de", file_type="default"
    )
    print(f"Pushed the translations: {json.dumps(details)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("command", choices=["pull", "push-source", "push-translations"])
    command = parser.parse_args().command
    token = os.environ.get("TX_TOKEN")
    if not token:
        sys.exit("TX_TOKEN isn't set: it needs a Transifex API token.")
    transifex = Transifex(token)
    try:
        {
            "pull": pull,
            "push-source": push_source,
            "push-translations": push_translations,
        }[command](transifex)
    except TransifexError as error:
        print(f"::error::Transifex: {error}")
        sys.exit(1)


if __name__ == "__main__":
    main()
