# Changelog — AMO27/PlayTorrioV2 fork

Changes made in this fork on top of upstream
[ayman708-UX/PlayTorrioV2](https://github.com/ayman708-UX/PlayTorrioV2),
on branch `fix/shutdown-music-comics`. Commit hashes are in brackets.

## Why this fork exists

The upstream app had problems that made it hard to use day to day: the app
froze or crashed when closing a movie or the window, music and comics stopped
working when their sources changed, several live-sports sources went offline,
and the updater pointed at upstream's builds. This fork fixes those, adds
clearer error messages so a failure says *why* instead of spinning forever,
and keeps Windows and iPhone builds working. Builds are manual-only (run the
workflow when you want one) so a push never starts a build by surprise.

## 2026-10-03

### Manga
- **Chapter numbers show correctly.** Every chapter was listed as "0.0".
  The number is now read from the chapter label in any common format
  ("Chapter 12", "Ch. 12.5", "Episode 3"), falls back to the chapter's place
  in the list if the site gives none, and shows "12" instead of "12.0".
  [48c6264]

### Anime
- **"No streams available" now says why.** The error screen lists what went
  wrong for each source (for example "site answered HTTP 403"), and says so
  when the show can't be found on the stream site, so the real cause can be
  fixed. [48c6264]

### Music
- **Crossfade.** A new button next to repeat in the music player cycles
  Off / 3 / 6 / 9 / 12 seconds. The end of a song fades out and the next one
  fades in when a song ends on its own. (The two songs don't overlap yet.)
  [48c6264]

## 2026-10-02

### Music
- **Unplayable songs are skipped.** In an album, playlist or saved songs, a
  song that can't be played is skipped instead of stopping the music; it only
  stops if every song in a row fails. [97159cb]
- **Clear error messages.** A red message says why a song failed (YouTube
  gave no link, or gave a link that wouldn't play). [97159cb]
- **iPhone no longer opens the YouTube app** when a song is requested; the
  hidden helper page is locked so it can't navigate away. [97159cb]
- Fallbacks when YouTube blocks the built-in extractor: several YouTube app
  "clients", a code-based unblocker, public Invidious/Piped mirrors, and the
  bundled yt-dlp on Windows.

### iPhone
- **Movies, TV and anime streaming/torrents work again** by pinning the
  torrent engine to 1.8.5 for the iOS build (1.9.9 broke it on iPhone).
- Music downloads save to the app's Documents folder.

### Windows
- **Minimize / maximize / close buttons are always visible.** The title bar
  followed the Windows light/dark setting while the app is always dark, so the
  icons could blend in until hovered. The title bar is now always dark.
  [97159cb]

## 2026-09-29

### Stability
- **Closing a movie no longer freezes or crashes the app.** The player is
  fully stopped before the torrent stream / 111477 proxy it was reading from
  is removed, each step is time-limited, and switching straight to another
  movie no longer tears down the new movie's stream. [34dbde7]

### Music
- **Live download progress snackbar.** Shows the current step (finding song,
  downloading, saving), a progress bar, percentage, size, time left and how
  many songs are queued, then a done/failed message. It uses the current
  theme's accent color with readable text: white on dark accents, dark on
  light ones (Midnight Black, Ocean, Emerald, Sunset), and bold white on
  Royal Purple. No more duplicate snackbars when the full-screen player is
  open. [3971808]

## 2026-09-28

### Live Matches
- **Replaced the dead sources** (PPV.to and dami-tv.pro were seized in
  "Operation Offsides"; cdn-live.tv no longer resolves) with **Dami TV
  (damitv.st)**, **SportsBite (sportsbite.org)** and **NTV Stream (ntv.cx)**.
  [84e9bca]
- Sport tabs, a "Live only" filter, a server picker for events with backup
  mirrors, pop-up/redirect ad blocking, clear error messages, and a
  hidden-browser fallback when a site's bot check blocks the match list.

### Security
- **Updater** checks this fork's releases instead of upstream's (so it can't
  replace this fork with the original build), verifies each download's
  SHA-256 fingerprint, and won't save a failed download as an installer.
  [56c4d03]
- **Local proxy** refuses to fetch addresses on the local network (router,
  NAS, Jellyfin, Tailscale devices), re-checking every redirect; the Jellyfin
  stream route only accepts links the app itself created. [56c4d03]
- **Jellyfin** accepts self-signed certificates only for servers on the local
  network; servers on public addresses need a valid certificate. [56c4d03]

## Earlier fixes

### App shutdown
- Closing the app no longer hangs: the window hides immediately, the music,
  audiobook and video players, torrent engine and local servers shut down in
  order with a time limit on each, and a watchdog force-closes the process
  if a native call gets stuck. [6ed39fa]

### Music
- No more endless loading: requests time out and show an error with Retry;
  songs that won't start report why instead of buffering forever.
  [6ed39fa, f5fb5c2]
- Playback falls back to the bundled yt-dlp when YouTube blocks the built-in
  extractor, and tries yt-dlp first. [ae5ac25, 469258d]
- **Downloads fixed.** They were silently failing every time; they now use
  the same stream lookup as playback, send browser-like headers, and show
  the real reason when one fails. [469258d, abc616b]
- Lyrics are found for many more songs via a fuzzy-search fallback on
  lrclib.net. [abc616b]
- Trending uses Apple Music's "Most Played" chart, with Deezer as a
  fallback. [7450218]

### Comics
- Comics load again after the old source went offline: readcomiconline.xyz
  is the primary source with readcomicsonline.ru as a backup, with scrapers
  rewritten for the sites' current layouts. [d4091ae, 25c85fb, 324f1b1]
- Failures show the actual reason with Retry, plus "Open in browser" when
  the site is blocking the app. [6ed39fa, f5fb5c2, 5b1b7bf]
- The comics homepage defaults to "Popular", with a toggle back to the full
  A–Z list. [7450218]

### IPTV
- M3U playlists get a TV guide (XMLTV): "Now playing" per channel and a
  short upcoming schedule. [7450218]

### Build
- One-click **Build Windows** GitHub Actions workflow, including the
  libtorrent_flutter native-library workaround it needs. [6ed39fa, 5266b3f]
- If a build fails with `ANGLE.7z Integrity check failed`, that's a GitHub
  download glitch: use **Re-run failed jobs**.
