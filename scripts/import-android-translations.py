#!/usr/bin/env python3
"""Fills App/Resources/Localizable.xcstrings from the Android app's translations.

The iOS app's strings mostly say what the Android app's do, so each iOS string that has an
Android equivalent (MAPPING below) takes that string's translations. Plurals come from the
Android plurals. Strings without an equivalent stay English until translated.

    scripts/import-android-translations.py ../Clementine-Android
"""

import html
import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ElementTree

# iOS string -> Android string name, or (array name, index) for a string-array item.
MAPPING = {
    "Welcome": "first_time_title",
    "Continue": "dialog_continue",
    "Cancel": "dialog_cancel",
    "Connect": "connectdialog_connect",
    "Address": "connect_address",
    "On your network": "connect_on_network",
    "Or enter its address": "connect_enter_address",
    "Search again": "connect_search_again",
    "Looking for Clementine…": "connect_searching",
    "Not showing up? Check that its network remote is turned on, or enter its address below.": "connect_searching_help",
    "Pick the Clementine you want to control. It needs to be on the same Wi-Fi as this phone.": "connect_intro",
    "Needs Clementine %@ or later, with Tools → Preferences → Network Remote turned on.": "connect_requirements",
    "Downloading data…": "connectdialog_download_data",
    "Connecting to Clementine…": "connectdialog_connecting",
    "Couldn't reach Clementine": "connectdialog_error",
    "Clementine on %@": "navigation_drawer_clementine_on",
    "Clementine Remote": "app_name",
    "Settings": "menu_settings",
    "Search": "menu_search",
    "Love": "menu_love",
    "Ban": "menu_ban",
    "Download": "menu_download",
    "Download playlist": "menu_download_playlist",
    "Player": "pref_cat_player",
    "Library": "library_title",
    "Downloads": "pref_cat_downloads",
    "Advanced": "pref_cat_advanced",
    "Connection": "pref_cat_connection",
    "About": "pref_cat_about",
    "Port": "pref_port_title",
    "Grouping": "pref_library_grouping_title",
    "Sorting": "pref_library_sorting_title",
    "Ascending": ("pref_library_sorting", 0),
    "Descending": ("pref_library_sorting", 1),
    "Artist": ("pref_library_grouping", 0),
    "Artist / Album": ("pref_library_grouping", 1),
    "Album artist / Album": ("pref_library_grouping", 2),
    "Artist / Year": ("pref_library_grouping", 3),
    "Genre / Album": ("pref_library_grouping", 5),
    "Genre / Artist / Album": ("pref_library_grouping", 6),
    "Album": "song_info_album",
    "Genre": "song_info_genre",
    "Year": "song_info_year",
    "Track": "song_info_track",
    "Disc": "song_info_disc",
    "Length": "song_info_length",
    "Size": "song_info_size",
    "Rating": "song_info_rating",
    "Play count": "song_info_playcount",
    "File": "song_info_filename",
    "Last.fm": "pref_lastfm_title",
    "Show buttons to love and ban songs.": "pref_lastfm_summary",
    "Close playlist": "playlist_close",
    "Clear playlist": "playlist_clear",
    "Remove from playlist": "playlist_context_remove",
    "This playlist is empty": "playlist_empty",
    "Search this playlist": "playlist_search_hint",
    "Add to playlist": "library_add_to_playlist",
    "Download library": "library_download_action",
    "Downloading the library…": "library_download",
    "Preparing the library…": "library_optimize",
    "No lyrics found.": "player_no_lyrics",
    "Disconnected": "player_disconnected",
    "Download started": "player_download_started",
    "Stop after this song": "player_stop_after_current",
    "Repeat track": "repeat_track",
    "Repeat album": "repeat_album",
    "Repeat playlist": "repeat_playlist",
    "Don't repeat": "repeat_off",
    "Shuffle all": "shuffle_all",
    "Shuffle albums": "shuffle_albums",
    "Shuffle tracks in this album": "shuffle_inside_album",
    "Don't shuffle": "shuffle_off",
    "Play": "notification_play",
    "Pause": "notification_pause",
    "Next": "notification_next",
    "Previous": "notification_previous",
    "Stop": "tasker_stop",
    "Next song": "tasker_next",
    "Play or pause": "tasker_playpause",
    "Disconnect": "tasker_disconnect",
    "Download complete": "download_noti_complete",
    "Download canceled": "download_noti_canceled",
    "Transcoding files": "download_noti_transcoding",
    "Starting download": "download_noti_title",
    "There isn't enough space on this phone": "download_noti_insufficient_space",
    "Clementine doesn't allow downloads. Turn them on in its Network Remote settings.": "download_noti_forbidden",
    "Downloads are only allowed on Wi-Fi": "download_noti_only_wifi",
    "No downloads": "downloads_empty",
    "Unknown": "unknown",
    "Done": "done",
    "Song": ("player_download_list", 0),
    "Playlist": ("player_download_list", 2),
    "Not connected": "widget_not_connected",
    "Version": "pref_version_title",
    "Authors": "dialog_about_authors",
    "Clementine": "pref_clementine_title",
    "Licence": "pref_license_title",
    "Open-source software": "pref_opensource_title",
    "Keep the screen on": "pref_keep_screen_on_title",
    "Replace existing files": "pref_dl_override",
    "Only on Wi-Fi": "pref_dl_wifi_only_title",
    "Download songs only when connected to Wi-Fi.": "pref_dl_wifi_only_summary",
    "Connect automatically": "pref_autoconnect_title",
    "Volume step": "pref_volume_inc_title",
    "Auth code": "input_auth_code",
    "That isn't a valid code": "invalid_code",
    "Clementine is too old": "error_versions",
    "Please update Clementine. You need Clementine %@ or later.": "old_proto",
    "Loading playlists": "player_download_playlists",
    "Search Clementine": "global_search_search",
    "Searching for “%@”…": "search_searching",
    "Find music in your library and in Clementine's internet services.": "global_search_empty",
    "Loved on Last.fm": "track_loved",
    "Banned on Last.fm": "track_banned",
    "Folders": "pref_dl_cat_folders",
    "Play on": "output_title",
    "Switching…": "output_switching",
    "Playing on %@": "output_playing_on",
    "Choose where to play": "output_choose",
    "%@ (this phone)": "output_this_phone",
    "Let Clementine play on this phone": "pref_renderer",
    "Internet": "internet_title",
    "Loading…": "internet_loading",
    "Set up in Clementine": "internet_needs_setup",
    "Nothing here": "internet_empty",
    "Play now": "internet_play_now",
    "Play next": "internet_play_next",
    "Replace playlist": "internet_replace_playlist",
    "Added to the playlist": "internet_added",
    "Playing next": "internet_playing_next",
    "Clementine can't add that to the playlist": "internet_not_playable",
    "That's no longer in Clementine": "internet_gone",
}

# iOS plural string -> Android plurals name.
PLURALS = {
    "%lld items": "number_items",
    "%lld songs": "queue_songs",
    "%lld selected": "queue_selected",
    "%lld songs added to the playlist": "songs_added",
}

# Plural strings with an English form but no Android equivalent.
ENGLISH_PLURALS = {
    "%lld items": ("%lld item", "%lld items"),
    "%lld songs": ("%lld song", "%lld songs"),
    "%lld selected": ("%lld selected", "%lld selected"),
    "%lld songs added to the playlist": ("%lld song added to the playlist", "%lld songs added to the playlist"),
    "Rated %lld stars": ("Rated %lld star", "Rated %lld stars"),
    "%lld songs added to %@": ("%lld song added to %@", "%lld songs added to %@"),
    "Rate %lld stars": ("Rate %lld star", "Rate %lld stars"),
}

# Plain strings with a single number, translated from an Android string.
NUMBERED = {
    "%lld min": "queue_minutes",
    "%lld h %lld min": "queue_hours_minutes",
}

LOCALES = {
    "ach": "ach", "ca": "ca", "cs": "cs", "de": "de", "el": "el", "es": "es", "et": "et",
    "fi": "fi", "fr": "fr", "hr": "hr", "hu": "hu", "it": "it", "ja": "ja", "ka": "ka",
    "ko": "ko", "lt": "lt", "ms-rMY": "ms", "my": "my", "nl": "nl", "pl": "pl", "pt": "pt-PT",
    "pt-rBR": "pt-BR", "ru": "ru", "sk": "sk", "sr": "sr", "sv": "sv", "tr": "tr", "uk": "uk",
    "uz": "uz",
}


def clean(text):
    """An Android resource string as plain text, with iOS format specifiers."""
    text = (text or "").strip()
    if len(text) >= 2 and text[0] == text[-1] == '"':
        text = text[1:-1]
    text = text.replace("\\'", "'").replace('\\"', '"').replace("\\n", "\n").replace("\\@", "@")
    text = html.unescape(text)
    text = re.sub(r"%(\d+)\$s", r"%\1$@", text)
    text = re.sub(r"%(\d+)\$d", r"%\1$lld", text)
    text = text.replace("%s", "%@")
    text = re.sub(r"%d", "%lld", text)
    return text


def read(path):
    strings, arrays, plurals = {}, {}, {}
    if not path.exists():
        return strings, arrays, plurals
    root = ElementTree.parse(path).getroot()
    for element in root:
        name = element.get("name")
        if element.tag == "string":
            strings[name] = clean("".join(element.itertext()))
        elif element.tag == "string-array":
            arrays[name] = [clean("".join(item.itertext())) for item in element]
        elif element.tag == "plurals":
            plurals[name] = {item.get("quantity"): clean("".join(item.itertext())) for item in element}
    return strings, arrays, plurals


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def write_catalog(path, catalog):
    """Writes the catalog as Xcode does, so that a build doesn't rewrite it: " : " between keys
    and values, keys sorted, an empty object over three lines, and no newline at the end."""
    text = json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", " : "), sort_keys=True)
    text = re.sub(r"^( *)(.* : )\{\}(,?)$", lambda m: f"{m.group(1)}{m.group(2)}{{\n\n{m.group(1)}}}{m.group(3)}",
                  text, flags=re.M)
    path.write_text(text, encoding="utf-8")


def main():
    android = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "../Clementine-Android") / "app/src/main/res"
    catalog = pathlib.Path(__file__).resolve().parent.parent / "App/Resources/Localizable.xcstrings"
    entries = {}

    for key, (one, other) in ENGLISH_PLURALS.items():
        entries.setdefault(key, {"localizations": {}})["localizations"]["en"] = {
            "variations": {"plural": {"one": unit(one), "other": unit(other)}}}

    english, _, _ = read(android / "values/strings.xml")
    for folder, locale in LOCALES.items():
        strings, arrays, plurals = read(android / f"values-{folder}/strings.xml")
        for key, source in MAPPING.items():
            if isinstance(source, tuple):
                items = arrays.get(source[0], [])
                value = items[source[1]] if source[1] < len(items) else None
            else:
                value = strings.get(source)
                # Untranslated strings are copies of the English.
                if value == english.get(source):
                    value = None
            if not value:
                continue
            # Keep only translations with the same placeholders.
            if sorted(re.findall(r"%(?:\d+\$)?(?:@|lld)", value)) and "%@" in key and "@" not in value:
                continue
            entries.setdefault(key, {"localizations": {}})["localizations"][locale] = unit(value)
        for key, source in PLURALS.items():
            forms = plurals.get(source)
            if not forms:
                continue
            entries.setdefault(key, {"localizations": {}})["localizations"][locale] = {
                "variations": {"plural": {quantity: unit(value) for quantity, value in forms.items()}}}
        for key, source in NUMBERED.items():
            value = strings.get(source)
            if value and value != english.get(source):
                entries.setdefault(key, {"localizations": {}})["localizations"][locale] = unit(value)
        rated = strings.get("song_info_rated")
        if rated and rated != english.get("song_info_rated"):
            value = rated.replace("$stars$", "%lld")
            entries.setdefault("Rated %lld stars", {"localizations": {}})["localizations"][locale] = unit(value)

    # Into the catalog's strings, which the build keeps up to date (scripts/sync-strings.sh), with
    # their translations from Transifex: only the translations taken from Android are replaced.
    existing = json.loads(catalog.read_text(encoding="utf-8"))
    for key, entry in entries.items():
        existing["strings"].setdefault(key, {}).setdefault("localizations", {}).update(entry["localizations"])
    write_catalog(catalog, existing)
    languages = {locale for entry in entries.values() for locale in entry["localizations"]}
    print(f"{len(entries)} strings, {len(languages)} languages")


if __name__ == "__main__":
    main()
