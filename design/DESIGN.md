# Clementine Remote for iOS: design

Clementine Remote for iOS controls the Clementine music player on a computer, over the local
network. It does everything the Android app ([Clementine-Android]) does, laid out as the Android
redesign has it (the "Clementine Remote redesign" canvas), in Clementine's design system, drawn with
iOS's own controls and patterns.

[Clementine-Android]: https://github.com/clementine-player/Android-Remote

- **Platform:** iOS 26 and later, iPhone and iPad. Swift 6, SwiftUI, Observation.
- **Look:** Clementine's colours (orange and plum, with Material 3 roles generated from them), light
  and dark following the system, or as chosen in Settings. SF Pro type at the design system's
  sizes. SF Symbols, with the Android app's own player glyphs where SF Symbols has no match.

## Contents

1. [Screens and navigation](#screens-and-navigation)
2. [Screen by screen](#screen-by-screen)
3. [Visual language](#visual-language)
4. [Behaviour](#behaviour)
5. [Architecture](#architecture)
6. [Platform differences from Android](#platform-differences-from-android)
7. [Settings](#settings)

## Screens and navigation

```
                    ┌──────────────┐
  launch ─────────▶ │   Connect    │  (shown whenever not connected)
                    └──────┬───────┘
                           │ connected
                           ▼
 ┌──────────────────────────────────────────────────────────────┐
 │ TabView                                                      │
 │  Queue │ Library │ Internet │ Search │ Downloads             │
 │                                                              │
 │  every tab: toolbar ConnectionChip ──▶ Connection sheet      │
 │                                          ├─ Switch Clementine│
 │                                          ├─ Settings (push)  │
 │                                          └─ Disconnect       │
 │                                                              │
 │  tabViewBottomAccessory: MiniPlayer ──▶ Player (full screen) │
 │                                          └─ Details / Lyrics │
 │                                             sheet            │
 └──────────────────────────────────────────────────────────────┘
```

| Android (today) | Redesign | iOS |
|---|---|---|
| Drawer: Search, Player, Playlists, Library, Downloads, Settings, Quit | Bottom navigation: Queue, Library, Internet, Search, Downloads | `TabView` with five `Tab`s (Internet only when Clementine can be browsed) |
| Player tab with pages Player, Song details, Clementine | Mini player above the navigation, full-screen player sheet | `.tabViewBottomAccessory` mini player; `.fullScreenCover` player with a zoom transition from it |
| Song details page | Details and lyrics bottom sheet | `.sheet` with medium and large detents; Details / Lyrics segmented control |
| Connection page, Settings and Quit in the drawer | Connection chip at the top right, opening the connection sheet | Toolbar button on every tab root; `.sheet` |
| Playlist spinner | Large app bar with the playlist name, chips to switch playlists | Large navigation title, horizontally scrolling chips |
| Library with its own back handling | Drill down with back navigation | `NavigationStack` pushes |
| Contextual action bar for multiple selection | Selection bar | `List` edit mode, actions in the bottom toolbar |
| Toasts | Toasts | A small capsule toast at the top of the screen, also posted as a VoiceOver announcement |
| Menu items in the app bar | Overflow menu | Toolbar `Menu` (ellipsis) |

On iPad, and in landscape on large iPhones, the tab view becomes a sidebar-adaptable tab view, the
player lays the artwork beside the song, and sheets are presented as forms.

## Screen by screen

### Connect

Shown at launch and whenever the app is not connected. From the redesign's Connect board.

- **Hero:** the brand gradient (plum → orange, left to right) behind the Clementine mark (168 pt,
  smaller on short screens, down to 96 pt) and "Clementine Remote" in 36 pt bold white. A settings
  button (gear, white) at the top right. The gradient runs under the status bar.
- **Intro:** "Pick the Clementine you want to control. It needs to be on the same Wi-Fi as this
  phone." in `on-surface-variant`.
- **On your network:** a section title with a refresh button ("Search again"). Below it a rounded
  (12 pt) `surface-container-low` group: one row per Clementine found by Bonjour
  (`_clementine._tcp`): a round `secondary-container` tile with a computer glyph, the service name,
  and "192.168.1.20 · port 5500". While none are found: a small spinner, "Looking for Clementine…"
  and help text.
- **Or enter its address:** a text field (URL keyboard, no autocorrect, Go key) with the addresses
  used before as suggestions below it while typing, and a filled Connect button.
- **While connecting:** a linear progress bar, "Connecting…" then "Downloading data…", and a Cancel
  button. The rest of the screen is disabled.
- **Footer:** "Needs Clementine 1.3 or later, with Tools → Preferences → Network Remote turned on."
- **Alerts:** the auth code prompt (numeric field; an invalid code keeps it open), couldn't connect
  (with the reason: not on Wi-Fi, not a private address, or check the address), and Clementine too
  old.
- Landscape: the hero fills the left half, the rest scrolls on the right.

### Queue (tab 1)

From the Queue board. The playlists Clementine has open.

- Large title: the playlist's name. Subtitle: "13 songs · 50 min" (`… h … min` above an hour).
- Toolbar: ConnectionChip, and a menu with New playlist, Download playlist, Close playlist, Clear
  playlist (asks first).
- `.searchable` filters the playlist by title, artist and album.
- Chips, one per playlist, then a "+" chip for a new playlist. The selected chip is filled
  `secondary-container` with a check.
- New playlist asks for a name; Clementine creates the playlist, and the queue shows it.
- Rows (media list items): a 48 pt rounded (8 pt) `surface-container-highest` tile with a note glyph,
  the title (one line), "artist · album", and the length at the end. The song playing has an
  equaliser glyph and its title in `primary`, medium weight.
- Tap plays the song (and makes its playlist the active one). Swipe to remove. "Select" enters edit
  mode: Play, Download, Remove in the bottom toolbar.
- While Clementine sends the playlists' songs, a determinate progress bar at the top.
- Opening the queue, or changing song, scrolls the playing song into view, three rows down.
- Empty: a note glyph and "This playlist is empty".

### Player (full screen)

From the Now playing board. Opened from the mini player; swipe down or the chevron to close.

- Top row: chevron-down (close), "Playing from" / the playlist's name, centred, and a menu (Stop,
  Download…).
- Artwork: square, full width with 24 pt gutters, 28 pt corners, on `surface-container-highest`.
  A song without a cover shows a `music.note` in `on-surface-variant`, 40% of the size, as the
  Android remote does; with nothing playing, the Clementine mark inset 32 pt. Tapping it shows the
  lyrics. Covers crossfade over 0.75 s.
- Song info, start-aligned: title (28 pt), artist in `primary` (16 pt medium), album in
  `on-surface-variant`, then "genre · year". One line each. A Love button (heart) beside it when
  Last.fm buttons are on.
- Seek bar: the position follows the finger while dragging and is sent on release. Times below
  (`m:ss`, monospaced digits); "Stream" before the position for streams; the length is hidden and
  the bar disabled when the length is unknown. Always left to right.
- Transport: shuffle · previous · play/pause · next · repeat, spaced evenly, always left to right.
  - Play/pause: 96 × 72 pt, `primary-container` fill, 36 pt `on-primary-container` glyph, 28 pt
    corners tightening to 16 pt while pressed. Long press: "Stop after this song".
  - Previous and next: 56 pt targets, 32 pt glyphs.
  - Shuffle and repeat: 48 pt, `on-surface-variant` when off, `primary` when on; each tap moves to
    the next mode and a toast names it ("Shuffle albums", "Repeat track"). Repeat track uses the
    repeat-one glyph.
- Volume: Clementine's volume (not the phone's) between speaker glyphs. The phone's volume buttons
  move it too. While Clementine plays on this phone, it's the phone's volume (an `MPVolumeView`),
  and the buttons change the phone's volume as usual.
- Bottom row: Lyrics and details, Queue (closes the player and shows the Queue tab), the output
  button when Clementine can play elsewhere (see [Remote streaming](#remote-streaming)), Download.
- Download asks what to download: this song, its album, or the playlist. Streams can't be
  downloaded.
- Landscape and iPad: artwork on the left at full height; song, seek bar and controls beside it.

### Details and lyrics sheet

From the Song details sheet board. Medium and large detents, grabber, 28 pt corners.

- Header: title (22 pt), "artist · album".
- Segmented control: Details / Lyrics.
- Details: rows of label (96 pt column, `on-surface-variant`) and value, with hairline separators:
  Album, Genre, Year, Track, Disc, Length, Play count, Size, File. Empty values are left out.
  Tapping the cover thumbnail shows the cover full size.
- Rating: five stars in `primary`, filled, half or empty from Clementine's rating. Tapping star *n*
  rates the song *n* stars and shows "Rated *n* stars". When Last.fm buttons are on: Love and Ban.
- Lyrics: asks Clementine for them the first time, with a spinner; shows the longest lyrics any
  provider found, with the provider's name, or "No lyrics found".

### Library (tab 2)

From the Library and Album boards. Clementine's library, copied to the phone.

- Large title "Library", subtitle "*n* items". Toolbar: ConnectionChip; a menu with Grouping (the
  seven groupings), Sort (ascending / descending) and Update library.
- `.searchable` (at the top level) searches the whole library as you type, matching as the
  Search tab does, and shows the results as it does, in sections (see Search). An artist or album
  found opens to its albums or songs, with Add to playlist and Download.
- Rows: artists (round `secondary-container` tile, person glyph), albums and years (disc glyph),
  genres (note glyph), each with "*n* items"; songs as media rows with "artist / album".
- Tapping a group pushes the level below. Its header: title, "*n* items", and **Add to playlist**
  (filled) and **Download** (tonal) buttons for everything in it. Tapping a song adds it to the
  playlist playing, and plays it if Clementine isn't playing, as double-clicking a song in
  Clementine does by default.
- **Add to playlist** adds to the playlist playing when tapped. Touched and held, it's a menu of
  every playlist, the one playing first, and **New playlist…**, which asks for a name, creates
  the playlist and adds to it. Search's Add to playlist works the same way.
- Select mode: Add to playlist, Download.
- Pull to refresh downloads the library again.
- Not on the phone yet: a disc glyph, "Your library isn't on this phone yet.", and a **Download
  library** button. While downloading: a determinate bar and "Downloading the library…", then an
  indeterminate bar and "Preparing the library…".
- The library is kept per Clementine: connecting to another Clementine deletes it.

### Internet (tab 3)

Clementine's internet services, browsed as its Internet sidebar shows them. Only there when the
Clementine connected to can be browsed (1.4.1-242 or later); the Android remote has the same screens.

- Large title "Internet": the services (SomaFM, Radio Browser, Jamendo, Subsonic, Plex, your radio
  streams…), each with its own icon on a round `secondary-container` tile. Toolbar: ConnectionChip.
- Tapping a node with children pushes the level below, titled with it. Rows have the node's title,
  and its subtitle (a track's artist) as the second line; nodes without their own icon have one for
  their kind (see Icons).
- Tapping a track or stream plays it if Clementine isn't playing, or else adds it to the playlist,
  as tapping a song in the library does. Touched and held, anything that can go on the playlist
  (albums and playlists too) has **Play now**, **Play next**, **Add to playlist** and **Replace
  playlist**. An opened node that can go on the playlist has a header: its title, "*n* items", and
  **Play** (filled) and **Add to playlist** buttons.
- "Loading…" with a spinner until the first answer, or while a service is still loading with
  nothing to show; an indeterminate bar at the top while it loads more. A service that has to be
  set up first: "Set up in Clementine", with Clementine's message saying where. An empty node:
  "Nothing here". Pull to refresh asks again.
- After adding: "Added to the playlist", or "Playing next"; nothing for Play now and Replace
  playlist, which the player shows. "Clementine can't add that to the playlist" and "That's no
  longer in Clementine" when it didn't work.

### Search (tab 4)

From the Search board. Searches everything Clementine can search (library and internet services).

- A search field at the top (`.searchable`, always shown), "Search Clementine". Submitting sends the
  search; a progress bar and "Searching for “…”" until Clementine finishes.
- Results are in sections by what matched, as music apps show them, filling in as providers
  answer. The Library tab's search shows the library's results the same way. Clementine doesn't say why a song matched, so the app works it out as Clementine's
  library search matches: each word must start a word of some field (ignoring case and accents).
  - **Top Result:** the best match, if an artist, album, song or station matched on its own:
    exactly, then by its start, then by its words. As good, an artist beats an album beats a song.
    Its second line says what it is ("Song · Radiohead").
  - **Songs:** titles that matched, or title, artist and album between them ("beatles help").
  - **Artists:** album artists (else artists) that matched; "*n* albums".
  - **Albums:** album names that matched, or name and artist between them, so an artist's albums
    are listed too; each with its artist.
  - **Stations:** internet radio (results that aren't files and have no album), with the provider's icon.
  - **Other matches:** songs that matched some other way, such as by genre, so none is lost.
- The first four of each section, the best first, with **See All** for the rest. Tapping a song or
  station adds it to the playlist playing, and plays it if Clementine isn't playing; an artist opens to its albums, and an album to its
  songs, with Add to playlist and select mode as in the library. See All has select mode too.
- "No results" and a first-run "Search your library and Clementine's internet services" message.

### Downloads (tab 5)

From the Downloads board.

- Large title "Downloads", subtitle "*x* free on this phone".
- **Downloading:** a row per job ("Album Suite bergamasque", "(2/4) Claude Debussy - Prélude" or
  "Transcoding (1/3)"), with a thin progress bar and "3.2 MiB / 18 MiB (1.1 MiB/s)". Cancel button.
- **On this phone:** finished jobs, with their result ("Download complete", "Canceled",
  "Insufficient space", …). Tapping one lists its songs; tapping a song plays it in the app. Swipe to
  remove from the list (the files stay).
- When downloads only run on Wi-Fi, a card says so with a **Change** button to the setting.
- Files are saved in the app's Documents folder under `Clementine/`, visible in the Files app.

### Connection sheet

From the Connection sheet board. Opened from the ConnectionChip.

- A 56 pt round tile with the computer glyph, "Clementine on *host*", and "Connected" in `primary`
  with a check.
- Facts: Address ("192.168.1.20 · port 5500"), Clementine version, Connected for (hh:mm:ss, live),
  Data (sent / received and the average rate, live).
- Actions: Switch Clementine (disconnects and shows Connect), Settings, Disconnect.

### Mini player

`.tabViewBottomAccessory`, shown while connected. Title and artist, a small cover (8 pt corners), the
output button when Clementine can play elsewhere, a small play/pause and next. The small cover
shows a music note for a song without one, as the player does. A thin `primary` progress line when the accessory is expanded. Tapping it
opens the player. With nothing playing it reads "No song playing".

### Settings

A grouped `Form`, pushed from the Connection sheet or opened from the Connect screen. See
[Settings](#settings).

## Visual language

The tokens are the design system's (`Clementine` design system, `tokens.json`), identical to
`ClementineTheme.kt` on Android. They live in the asset catalogue as named colours with light and
dark appearances, and are reached through `Color.clementine.*`.

### Colour

| Role | Light | Dark | Used for |
|---|---|---|---|
| `clementine-orange` | #db6835 | same | identity: the gradient, the mark |
| `clementine-orange-ui` | #c05422 | same | fills that carry white text |
| `clementine-plum` | #af597d | same | the gradient's start |
| `primary` | #9f3c09 | #ffb598 | accents: artist line, active toggles, seek bar, tint |
| `on-primary` | #ffffff | #591c00 | text on `primary` |
| `primary-fill` | #9f3c09 | #c05422 | filled buttons the system labels white: Connect, Done, Add to playlist |
| `primary-container` | #c05422 | #e46f3b | play/pause |
| `on-primary-container` | #fffbff | #431300 | play/pause glyph |
| `secondary-container` | #fdb69a | #6e3c27 | selected chips and rows, icon tiles |
| `on-secondary-container` | #79452f | #eea88d | |
| `surface` | #fff8f6 | #1b110d | every screen's background |
| `surface-container-low` | #fff1ec | #241915 | sheets, grouped cards |
| `surface-container` | #ffe9e2 | #281d19 | tab bar |
| `surface-container-high` | #f9e4dc | #332723 | search field, ConnectionChip |
| `surface-container-highest` | #f3ded7 | #3f322d | artwork and thumbnail grounds |
| `on-surface` | #241915 | #f3ded7 | primary text |
| `on-surface-variant` | #57423a | #dec0b6 | secondary text, inactive icons |
| `outline` | #8a7269 | #a58b81 | chip outlines |
| `outline-variant` | #dec0b6 | #57423a | separators |
| `error` | #ba1a1a | #ffb4ab | errors, with a word or glyph |
| `error-container` | #ffdad6 | #93000a | offline ConnectionChip |

Rules, from the design system:

- White text only on `clementine-orange-ui`, never on `clementine-orange`. Filled buttons, whose
  labels the system draws white, take `primary-fill`, not `primary`: dark `primary` is too pale for
  white (1.7:1).
- The brand gradient (plum → orange, left to right) only on the Connect hero. Only the mark and
  large bold type sit on it.
- Chrome is tonal: navigation bars on `surface`, the tab bar on `surface-container`. Orange carries
  meaning: play/pause, progress, the current song, selection.
- The app's tint is `primary`.

### Type

SF Pro (the system font) at the design system's sizes, scaled with Dynamic Type:

| Style | Size / line | Used for |
|---|---|---|
| display | 36 / 44 bold | "Clementine Remote" on the hero |
| headline-medium | 28 / 36 | song title on the player |
| headline-small | 24 / 32 | album header |
| title-large | 22 / 28 | sheet titles |
| title-medium | 16 / 24 medium | artist |
| body-large | 16 / 24 | list titles, values |
| body-medium | 14 / 20 | meta lines |
| label-large | 14 / 20 medium | section titles, buttons |
| label-medium | 12 / 16 medium | times, "genre · year" (monospaced digits) |

One line per fact, truncated at the end; song titles never wrap.

### Shape, space, motion

- Spacing on a 4 pt grid: 4, 8, 12, 16, 24, 32. Player gutters 24, gaps 16.
- Corners: 28 (artwork, play/pause, sheets), 16 (mini player), 12 (grouped cards), 8 (thumbnails,
  chips); capsules for buttons, search and the seek track.
- Flat: no shadows beyond what iOS's own materials draw.
- Touch targets at least 44 pt (48 where the design says so).
- Motion: covers crossfade over 0.75 s; play/pause corners tighten while pressed (~0.2 s); the seek
  thumb follows the finger. Nothing moves by itself.

### Icons

SF Symbols, filled, in the colour of their control:

| Use | Symbol |
|---|---|
| Play / pause | `play.fill` / `pause.fill` |
| Previous / next | `backward.end.fill` / `forward.end.fill` |
| Shuffle / repeat / repeat track | `shuffle` / `repeat` / `repeat.1` |
| Queue / Library / Internet / Search / Downloads | `list.bullet` / `square.stack` / `globe` / `magnifyingglass` / `arrow.down.circle` |
| Internet folder / track / stream / smart playlist | `folder` / `music.note` / `dot.radiowaves.left.and.right` / `wand.and.stars` |
| Play next / Replace playlist | `text.line.first.and.arrowtriangle.forward` / `arrow.triangle.2.circlepath` |
| Computer (host) | `desktopcomputer` |
| Playing | `waveform` (animated only when Reduce Motion is off) |
| Song / album / artist | `music.note` / `opticaldisc` / `person.fill` |
| Love / ban | `heart` / `hand.thumbsdown` |
| Lyrics | `quote.bubble` |
| Stars | `star.fill` / `star.leadinghalf.filled` / `star` |

The Clementine mark (from the desktop repo's `data/icon.svg`) is the app icon, the Connect hero and
the cover when nothing's playing. A song without a cover has a music note instead: Clementine sends
its "no cover" picture (a jewel case, not square) for such a song, which the app recognises by its
empty `art_automatic` and `art_manual` (or an `art_manual` of `(unset)`) and doesn't show, as the
Android remote does.

### Copy

Plain, short, sentence case, as the design system says: "Connect", "Add to playlist", "No song
playing", "Clementine on studio-pc". Mode feedback names the new mode. Where a string says what an
Android string says, `scripts/import-android-translations.py` copies that string's translations into
the String Catalog; the rest are English until translated.

## Behaviour

### Connecting

- One TCP connection to Clementine (default port 5500). Each message is a big-endian 32-bit length
  and a `pb.remote.Message` (proto2, version 21). Messages over 50 MB, or from a Clementine older than
  version 21, end the connection.
- The first message is `CONNECT` with the auth code, `send_playlist_songs = true` and
  `downloader = false`. Clementine answers with `INFO` ("Downloading data…"), the current song,
  playlists and state, then `FIRST_DATA_SENT_COMPLETE`, when the app shows the tabs.
- `DISCONNECT` with *Wrong auth code* or *Not authenticated* asks for the code and tries again.
- Clementine sends `KEEP_ALIVE` regularly. Nothing for 25 s means the connection is lost: the app
  reconnects (`send_playlist_songs = false`) up to 5 times, then shows "Connection lost" and returns
  to the Connect screen. A failed send also reconnects once.
- The address, auth code and addresses used before are saved, and the name of the Clementine
  connected to if it was picked from the network. With "Connect automatically" on (the default),
  the Connect screen connects to the saved address at launch, which is quickest when it hasn't
  changed. If Clementine can't be reached there and it was picked from the network, the screen
  says nothing and waits for it to show up there by name, then connects to its new address; if
  it shows up at a new address sooner, it connects there without waiting for the old one to time
  out. This happens once per launch, and stops once something else is connected to, the settings
  are opened or connecting is canceled: disconnecting doesn't reconnect.
- In the background iOS suspends the app, and the connection with it. When the app is sent to the
  background it keeps the connection for as long as iOS allows, then disconnects quietly; on return
  it reconnects without asking for the playlists again. Downloads in progress ask iOS for extra
  background time.

### Player state

`RemoteSession` holds what Clementine last said: the song, state, position, volume, shuffle and
repeat modes, playlists and their songs, the active playlist, lyrics and version. Some changes show
at once rather than waiting for Clementine to confirm them: seeking, rating, and cycling shuffle and
repeat (the next mode is set locally, then sent whole).

- Shuffle cycles Off → All → Inside album → Albums. Repeat cycles Off → Track → Album → Playlist.
- A song can be loved once.
- Lyrics: `GET_LYRICS` the first time; the longest provider's lyrics win.

### Volume buttons

The phone's volume buttons change Clementine's volume, not the phone's, while the app is in front.
The app keeps an ambient audio session active (it plays nothing and doesn't interrupt other audio),
watches the session's output volume, and after each press puts the phone's volume back where it was
through a hidden `MPVolumeView`, so presses keep registering even at 0 % and 100 %. Each press moves
Clementine's volume by the "Volume step" setting and shows "Volume 60%". The system volume HUD is
hidden while the app is active.

### Remote streaming

Clementine 1.4 with *Allow playing on remote devices* on can play on its remotes instead of its
computer, as the Android remote does. The
protocol is Clementine's: `RENDER_*` messages to a renderer, `RENDERER_*` back, `OUTPUTS` to every
remote.

- **Offering the phone:** unless the "Let Clementine play on this phone" setting is off, the
  connect request carries the phone's renderer capabilities: a UUID kept in `renderer_id`, the
  device's name, the formats AVFoundation plays (MP3, AAC/MP4, FLAC, WAV, AIFF; Clementine converts
  Ogg to MP3), and gapless and Range support. Clementine without streaming ignores it.
- **Choosing an output:** when Clementine's info lists `SERVER_FEATURE_RENDERING`, the app asks
  for its outputs. With more than one, an output button (devices glyph, or the active device's
  glyph in `primary` when not the computer) shows in the mini player and the player. It opens a
  "Play on" sheet: Clementine's computer ("Clementine on studio-pc"), "iPhone (this phone)", and
  other remotes as speakers, with a checkmark on the active one and "Switching…" while playback
  moves. Picking one sends `SET_OUTPUT`.
- **Playing here:** `Renderer` (ClementineKit) plays what Clementine sends with `AVPlayback`, an
  `AVQueuePlayer`, and reports its state, with the position every second while playing. Clementine
  stays in charge of what plays: the phone preloads the next track when told, and says when one
  ends or fails (network failures as transient, so Clementine reloads).
- **In the background:** the app has the `audio` background mode. While Clementine plays here the
  connection stays open in the background; once it stops, the app lets it go as usual. iOS pauses
  playback for calls, and Clementine shows it paused.
- **Lock screen:** while playing here, Now Playing shows the song and the cover, and its buttons
  control Clementine.
- **Security:** the tracks come over plain HTTP from Clementine's computer, allowed by
  `NSAllowsLocalNetworking` and `NSAllowsArbitraryLoadsForMedia`.

### Playlists

- On opening the Queue, the app asks for the songs of every playlist it doesn't have yet
  (`REQUEST_PLAYLIST_SONGS`), showing how many have arrived.
- Play: `CHANGE_SONG` (playlist id, song index); that playlist becomes the active one.
- Remove: `REMOVE_SONGS` with the songs' indices. Clear playlist removes every song. Close playlist:
  `CLOSE_PLAYLIST`.
- Adding from the library: `INSERT_URLS` with URLs, into the playlist picked (the active one
  unless another is picked). Adding from search: `INSERT_URLS` with the songs' metadata.
- New playlist: `UPDATE_PLAYLIST` with `create_new_playlist` and the name (Clementine 1.4 and
  later; the Android app's protocol doesn't have it, so the app's copy adds it). Clementine
  creates the playlist, switches to it and sends `PLAYLISTS`; the new id there is the new
  playlist. Adding to a new playlist creates it this way first, then adds to its id: Clementine's
  own `new_playlist_name` in `INSERT_URLS` adds songs with metadata to the old playlist. If no new
  playlist arrives within 5 s, the app says creating playlists needs Clementine 1.4.

### Library

- Downloaded over a second connection (`downloader = true`) with `GET_LIBRARY`: SQLite database file
  in `LIBRARY_CHUNK`s, written to Application Support.
- Then: delete unavailable songs, create the `songs_fts` FTS3 table and the artist, album and title
  indices, as Android does.
- Browsing runs the same queries as Android's `DynamicSongQuery`: each level groups by one field of
  the grouping, songs are ordered by album, disc and track, and each group's "*n* items" counts the
  distinct values below it. Filtering matches `songs_fts MATCH "text*"`.
- Groupings: Artist; Artist / Album (default); Album artist / Album; Artist / Year; Album;
  Genre / Album; Genre / Artist / Album. Sorting: ascending (default) or descending.

### Internet

The protocol is Clementine's (clementine-player/Clementine#7530), which the Android remote speaks too.

- Clementine that can be browsed lists `SERVER_FEATURE_BROWSE` in its info; only then is the tab
  shown. If it goes while shown, the app goes to the Queue.
- `REQUEST_BROWSE` with a node id lists that node's children, or the services without one, 500 at
  most from an offset. Clementine answers `BROWSE`: the page, the number of children in all, and a
  state: ready, loading (more follows), needs setup (with a message to show) or gone (the level
  goes back up). It sends the node again whenever its children change, for as long as it's the
  node last asked for, so a level is asked for again whenever it's shown (going back up, or coming
  back to the tab).
- Reaching the last row asks for the next page, if there are more; a page replaces the rows from
  its offset, and the list is cut to the number there are.
- Node ids last as long as the connection: a new connection's `INFO` forgets them all, and the tab
  goes back to the services.
- `REQUEST_BROWSE_ADD` puts nodes on Clementine's current playlist, as a drag from its sidebar does:
  append, play now, play next or replace. `BROWSE_ADD_RESULT` says whether it worked; if a node has
  gone, the level is asked for again.

### Search

- `GLOBAL_SEARCH` with the query. `GLOBAL_SEARCH_STATUS` *started* gives the search's id; results
  (`GLOBAL_SEARCH_RESULT`) for that id go into an in-memory SQLite table, with each provider's icon;
  *finished* shows them. Grouped by provider, then the library grouping.

### Downloads

- Each job is its own connection (`downloader = true`) sending `DOWNLOAD_SONGS`: the current song,
  its album, a playlist, or a list of URLs.
- For each song Clementine first offers it (chunk 0, with the song's metadata); the app accepts
  unless the file exists and overwriting is off (`SONG_OFFER_RESPONSE`). Then chunks until
  `chunk_number == chunk_count`. `DOWNLOAD_TOTAL_SIZE` gives the total, `TRANSCODING_FILES` the
  transcoding progress, and `DOWNLOAD_QUEUE_EMPTY` ends the job. `DISCONNECT` means downloads are
  turned off in Clementine.
- Files go to `Documents/Clementine/[playlist/][artist/[album/]]filename`, depending on the
  settings, with the characters the Android app keeps out of file names removed (except "-", which
  is harmless). A partly written file is deleted.
- Results: complete, canceled, insufficient space, can't save, connection error, forbidden, Wi-Fi
  only.
- A local notification says when downloads finish while the app is in the background. The app
  asks for permission to notify when the first download starts.

### Shortcuts

App Intents replace the Android app's Tasker plugin: Connect, Disconnect, Play, Pause, Play/pause,
Next, Stop. They appear in Shortcuts, Siri and automations. When the app isn't connected, an intent
opens a short connection, sends its command and disconnects.

### Widget

The app shares the last Clementine and song with the widget and the intents through the app group
`group.org.clementine-player.remote`.

A home screen widget (WidgetKit) with the last song seen and play/pause and next buttons (App
Intents, as above). It can't update live while the app is suspended; it shows what the app last saw.

## Architecture

```
ClementineRemote.xcodeproj           (generated from project.yml by XcodeGen)
├─ App/                              SwiftUI app
│  ├─ ClementineRemoteApp.swift      scene, dependencies
│  ├─ Theme/                         colours, type, shapes, reusable views
│  ├─ Connect/  Queue/  Player/  Library/  Internet/  Search/  Downloads/  Connection/  Settings/
│  ├─ Streaming/                     AVPlayback (AVQueuePlayer), NowPlaying (lock screen)
│  └─ Resources/                     Assets.xcassets, Localizable.xcstrings
├─ Widget/                           widget extension
└─ Packages/ClementineKit/           Swift package: everything testable without UI
   ├─ Protocol/      generated remotecontrolmessages.pb.swift, framing, message builders
   ├─ Connection/    MessageStream (NWConnection, framing), ClementineConnection (actor:
   │                 connect, keep-alive, reconnects, byte counts)
   ├─ Discovery/     ServiceBrowser (NWBrowser, resolution to IPv4)
   ├─ Model/         Song, Playlist, modes, LyricsProvider
   ├─ Session/       RemoteSession (@MainActor @Observable): state and commands
   ├─ Browse/        SQLite wrapper, SongQuery, SongBrowser, LibraryStore, SearchStore
   ├─ Internet/      InternetBrowser: Clementine's internet services, level by level
   ├─ Downloads/     DownloadManager, SongDownloader, DownloadStorage
   ├─ Settings/      Settings keys and defaults
   └─ Streaming/     Renderer: plays what Clementine sends, through a Playback
```

- **Only dependency:** swift-protobuf. SQLite is the system library, through a small wrapper.
- **Protocol file:** `Packages/ClementineKit/Proto/remotecontrolmessages.proto`, the Android app's
  copy. `scripts/generate-proto.sh` regenerates the Swift.
- **Concurrency:** network I/O in actors; UI state on the main actor; the SQLite work in a
  background actor.
- **Testing:** Swift Testing in the package: framing and parsing, message builders, the connection
  against an in-process fake Clementine, song offers and chunking, `SongQuery` on a sample library,
  and the session's state changes, the renderer against a fake player, and the internet browser's
  paging and updates. UI tests cover
  connecting and the tabs against the fake server.
  On pull requests, a UI test also screenshots every screen, light and dark, against a real
  Clementine, and posts them on the pull request (`.github/workflows/screenshots.yml`).

## Platform differences from Android

| Android | iOS |
|---|---|
| Foreground service keeps the connection in the background | Connection kept while iOS allows, then reconnected on return |
| Media notification and lock screen controls | Lock screen controls while Clementine plays on the phone |
| Lower volume during calls | Not provided |
| Volume keys control Clementine | Kept (see [Volume buttons](#volume-buttons)) |
| Wake lock | Not applicable |
| Keep screen on | `isIdleTimerDisabled` while connected and the setting is on |
| Download directory setting, MediaStore | The app's Documents folder, shown in Files |
| Open downloaded songs in another app | Play them in the app, or share them |
| Tasker plugin | App Intents (Shortcuts) |
| Home screen widget | WidgetKit widget |
| Dynamic (wallpaper) colour | Not applicable: Clementine's colours always |
| Unused "show track number" setting | Dropped |

## Settings

| Section | Setting | Default | Android key |
|---|---|---|---|
| | Appearance: System, Light or Dark | System | none (`pref_appearance`) |
| Player | Volume buttons control Clementine | on | `pref_volumekey` |
| | Volume step | 10 % (1–20 %) | `pref_volume_inc` |
| | Show Last.fm buttons | on | `pref_show_lastfm` |
| Library | Grouping | Artist / Album | `pref_library_grouping` |
| | Sorting | Ascending | `pref_library_sorting` |
| Downloads | Only on Wi-Fi | off | `pref_dl_wifi_only` |
| | Replace existing files | off | `pref_dl_override` |
| | Playlist folder | off | `pref_dl_pl_save_own_dir` |
| | Artist folder | on | `pref_dl_artist_dir` |
| | Album folder (needs artist folder) | on | `pref_dl_album_dir` |
| Connection | Connect automatically | on | `pref_autoconnect` |
| | Let Clementine play on this phone | on | `pref_renderer` |
| | Port | 5500 | `pref_port` |
| Advanced | Keep the screen on | off | `pref_keep_screen_on` |
| About | Version, Clementine's website, the source code, credits, licences | | |

Saved state: last address (`save_clementine_ip`), its network name (`last_server_name`), addresses
used (`known_ips`), last auth code (`last_auth_code`), the Clementine the library came from
(`library_ip`), this install's renderer id (`renderer_id`).
