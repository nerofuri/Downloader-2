# Downloader 2

A Chrome-style iOS browser with an IDM-style download manager, video sniffer,
HLS (m3u8) downloader, background downloads, batch downloads and a built-in
ad blocker. Built with SwiftUI + WebKit, no third-party dependencies.

## Features

- **Browser** — Chrome-inspired UI: omnibox with search/URL detection, bottom
  toolbar, tab grid switcher, Incognito tabs, new-tab page with shortcuts,
  desktop-site mode, pull gestures for back/forward.
- **Video sniffer** — a script injected into every page watches `<video>`/`<audio>`
  elements and hooks `fetch`/XHR, so media the page plays (mp4, webm, m3u8, mp3, …)
  shows up in a floating **download badge**. Tap it to download any detected stream.
- **Download manager** — background `URLSession` engine: downloads keep running
  when you leave the app or lock the phone, survive app relaunches, support
  pause/resume (byte-range resume), progress, and land in `Files app → Downloader 2 → Downloads`.
- **HLS / m3u8** — two modes:
  - *Save for offline* (recommended): native `AVAssetDownloadTask`, fully
    background-capable, playable in the built-in player.
  - *Export as video file*: parses the playlist, picks the best variant,
    downloads all segments (AES-128 encrypted streams are decrypted) and writes
    a single `.ts`/`.mp4` file you can share anywhere. Best run in the foreground.
- **Batch downloads** — paste a list of URLs (one per line), or "Download All"
  detected media on a page.
- **Ad blocker** — WebKit content-rule blocking of ~50 major ad/tracker networks
  plus cosmetic hiding of common ad containers. Toggle in Settings.
- **Player** — AVPlayer-based, plays downloads and offline HLS with
  Picture-in-Picture.
- **IDM-style catch** — navigating to any file the browser can't display
  (zip, pdf attachment, binary, direct video link…) automatically becomes a download.

## Getting the IPA

Every push runs the **Build unsigned IPA** GitHub Actions workflow on a macOS
runner:

1. Open the repo's **Actions** tab → latest *Build unsigned IPA* run.
2. Download the `Downloader2-unsigned-ipa` artifact.
3. Sign `Downloader2-unsigned.ipa` with your Apple certificate
   (Sideloadly, esign, iOS App Signer, Xcode, `zsign`, …) and install it.

## Building locally (macOS)

```bash
brew install xcodegen
xcodegen generate
open Downloader2.xcodeproj
```

## Known limitations

- **Playback formats**: playback uses iOS `AVPlayer`, which supports mp4, mov,
  m4v, ts, HLS, mp3, aac, wav. Formats like mkv/avi/webm can still be
  *downloaded* and shared to a player app such as VLC, but may not play in the
  built-in player (iOS has no system codecs for them).
- **DRM**: FairPlay / SAMPLE-AES / Widevine protected streams are deliberately
  not downloadable.
- **HLS export to file**: exporting an m3u8 to a single file runs as a normal
  task, so iOS gives it limited background time — use *Save for offline* for
  long streams you want downloaded in the background.

## Legal

Only download content you have the right to save. Respect copyright law and the
terms of service of the websites you visit.
