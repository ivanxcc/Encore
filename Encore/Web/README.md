# Encore Web

Encore in a browser, for devices that can't install the apps (a Tesla, a smart TV, a work laptop),
built as a web product in its own right rather than a port of the apps.

Status: **phase 1**. The relay and its lab page exist ([../Relay](../Relay/README.md)); the web app
itself comes after the relay's numbers are confirmed on real devices.

## What "as fast as the big services" takes

They are fast because they encode ahead of time, cut video into chunks that play independently, and
serve from nearby. Encore Web gets the same properties without encoding anything:

1. **Choose a source the browser already plays.** Add-ons list many releases of a title; the web
   ranking prefers H.264 at up to 1080p, ready (cached) now. Converting video is the rare fallback.
2. **Direct play** when the file is MP4 with H.264 and AAC: the browser streams from the source.
3. **Repackage, never restart.** Matroska files go through the relay: the stream is planned from the
   file's keyframe index, so every seek is one independent segment.
4. **Start before Play.** Opening a title's page resolves its sources and asks the relay to prepare
   the first segments at the resume point; near the end of an episode the next one is prepared too.
5. **Adapt by source, not by encoding.** On a weak connection the player moves to a leaner release
   (the same picker as Downloads' Data Saver).
6. **Convert only as a last resort**, on the home server's hardware encoder (HEVC or HDR sources only).

Targets, measured on the device by the lab page and later by the player's own stats overlay:

| | Target |
| --- | --- |
| Press Play to first frame | under 1.5 s (under 1 s when prepared ahead) |
| Seek to picture | under 1 s |
| Stalls during normal playback | none |

## Where things run (all free tiers)

| Piece | Where |
| --- | --- |
| The web app (static) | Cloudflare Pages |
| Sign-in, profiles, progress | Encore Cloud (the existing Worker; it now allows browser calls) |
| Relay | Oracle Cloud free-tier server (datacenter bandwidth) |
| Video conversion, rare | Home server with a hardware encoder, reached over Tailscale |

Video never passes through Cloudflare.

## The app (phases 3 and on)

- **Its own design for the web**: pointer, touch, keyboard, and D-pad are all first-class; big targets
  for a car's screen; shared-element page transitions (View Transitions); glass that falls back to
  solid fills on slow hardware; reduced-motion and focus styles throughout.
- **Sign in by QR** with Encore pairing; profiles and Continue Watching shared with the apps.
- **Player**: Encore's controls, Skip Intro, Up Next and Watch Credits, audio and subtitle choices,
  keyboard shortcuts, lock-screen controls (Media Session), Picture in Picture, AirPlay in Safari,
  screen wake lock, a stats overlay.
- **Installable** (PWA), with the shell cached for instant launch.
- **Progress** is written by small patches to Encore Cloud, applied on the server, so the web app
  never rewrites a household document.

## Phases

1. **Prove it**: relay + lab page on the server. *(done: see Measured; the Tesla run is still to come)*
2. **Relay, complete**: subtitles as WebVTT, audio track switching, segments streamed while being
   made, tokens minted by Encore Cloud.
3. **The web app**: browse, title pages, player, sign-in, sync.
4. **Conversion fallback** on the home server; HEVC and Dolby passthrough for Safari.
5. **Polish**: scrub thumbnails, source-level quality adaptation, PWA install.

## Measured (phase 1, iPad Safari, relay on Oracle Cloud, TorBox sources)

Lab reports from 2026-11-14, after four rounds of relay fixes:

| | Target | Measured |
| --- | --- | --- |
| Video start once a source is chosen | under 1.5 s | 1.0–3.1 s |
| Stalls | none | 0–1 per title |
| Seek, median | under 1 s | 2.2–3.6 s (outliers 6–13 s when the source itself slowed) |
| Direct play (MP4), seek median | | 1.5 s |
| Add-on source lookup (AIOStreams) | | 1.4–6.4 s |
| Add-on handing over the debrid link | | 0.4–2.1 s |

What the rounds established:

- **One connection per file.** TorBox gives one connection 12–70 Mbps to the Oracle server and
  slows a file read over several at once (to 1–3 Mbps over six). Parallel reads are off by default;
  a seek must stop the previous run, never run beside it.
- **The server reaches the debrid host fine.** Only one Torrentio link was refused from the
  datacenter (HTTP 403); trying the next source handled it.
- **Safari**: video must be started on the tap (or muted, with a sound button); native HLS is used
  on Safari (it passes Dolby audio through); `requestVideoFrameCallback` stops firing after a few
  reloads, so playback detection also watches the clock.
- **Ranking**: prefer H.264, AAC, and about 8 Mbps or less; add-on text needs Unicode folding (NFKC)
  to read their styled numbers.

## Next relay work (before or alongside the app)

1. **Serve a segment while it's being made** (chunked response that follows the growing part file):
   expected to cut about a second from every seek and from the first frame.
2. **Remember each file's index** (keyed by the source URL without its token): repeat plays skip the
   index read (0.6–4.4 s measured).
3. **Prepare from the title page**: resolve sources and open a relay session at the resume point as
   soon as a title page opens; near the end of an episode, prepare the next.
