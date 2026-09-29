# Changelog — AMO27/PlayTorrioV2 fork

Changes made in this fork on top of upstream
[ayman708-UX/PlayTorrioV2](https://github.com/ayman708-UX/PlayTorrioV2),
on branch `fix/shutdown-music-comics`. Commit hashes are in brackets.

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
