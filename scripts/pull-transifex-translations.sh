#!/bin/bash
# Pulls the translations from Transifex and merges them into App/Resources/Localizable.xcstrings
# (scripts/merge-transifex-translations.py). Run by .github/workflows/translations.yml: every
# night, to commit them, and before each push of the catalog, which would otherwise erase them on
# Transifex (see that workflow).
set -euo pipefail
cd "$(dirname "$0")/.."
# Transifex's onlytranslated mode can leave reviewed translations out, as it does for the Android
# remote's files, and onlyreviewed leaves out those not reviewed yet: both are pulled, and the
# merge takes the translations from each. Only translated strings: the app shows English for the
# rest by itself. (A mode with nothing to give may write no files at all.)
shopt -s nullglob
rm -rf build/transifex build/transifex-reviewed
mkdir -p build/transifex
tx pull --all --force --mode onlyreviewed --silent
mv build/transifex build/transifex-reviewed
mkdir -p build/transifex
tx pull --all --force --mode onlytranslated --silent
scripts/merge-transifex-translations.py build/transifex-reviewed/*.xcstrings build/transifex/*.xcstrings
