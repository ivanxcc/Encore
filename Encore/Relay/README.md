# Encore Relay

Prepares remote video files for web browsers, for [Encore Web](../Web/README.md). It never re-encodes
video. For each file a browser wants to play, it answers one of:

| Answer | When | What plays |
| --- | --- | --- |
| `direct` | MP4 whose codecs the browser decodes (read from its movie box in a few ranged reads) | The browser streams the source itself; the relay is not involved |
| `remux` | Matroska with H.264 | An HLS stream from the relay: video copied untouched, audio converted to AAC only if the browser can't decode it |
| `unsupported` | HEVC, AV1, HDR, 10-bit, no keyframe index | Nothing: the player picks another source (most titles have an H.264 release) |

## Why seeking is instant

A typical media server runs one long conversion and restarts it when you seek past what it has made.
The relay instead reads the file's keyframe index (Matroska Cues, a few hundred kilobytes fetched by
range) and lays out the whole stream before reading any media: every segment starts on a known
keyframe at a known byte offset. Any segment can then be made on its own:

1. Fetch the file from that segment's cluster offset: ranged requests, six at a time over separate
   connections, small at first (so the first segment's few megabytes arrive together) then larger.
   Debrid hosts often cap each connection's speed; parallel requests add up.
2. Pipe a small synthesized header plus those bytes through `ffmpeg -c:v copy`.
3. Cut ffmpeg's transport stream at the planned keyframes into segments.

A seek is one segment made from one ranged read. The run keeps going ahead of the viewer (up to about
100 seconds, then it is held back by backpressure), so normal playback never waits. Timestamps come
from the file, so segments made by different runs are identical and interchangeable; the tests check
this frame by frame.

## API

```
POST   /v1/session            {url, headers?, start?, audio?, language?, caps: {video: [...], audio: [...]}}
                              Authorization: Bearer <token>     -> a decision (see above), with the playlist path
GET    /v1/s/{id}/index.m3u8  the complete VOD playlist
GET    /v1/s/{id}/seg/{n}.ts  a segment (Server-Timing says how long it took to prepare)
DELETE /v1/s/{id}             close a stream early (idle streams close after 15 minutes)
POST   /v1/speed              {url, headers?}  -> the relay's own link to that source: first byte time,
                              one connection's throughput, and six connections'
GET    /v1/stats              counters (token required)
GET    /lab                   the lab page: time real titles on any device
```

Access is by signed, expiring tokens (`encore-relay token`); stream ids are unguessable. The relay
refuses to fetch private, loopback, and link-local addresses, checked at connection time so redirects
and DNS tricks are covered. It keeps no logs of what is played.

## Install on a server

On Ubuntu or Debian (Oracle Cloud free tier works, x86 or Arm):

```sh
curl -fsSL https://github.com/ivanxcc/Encore/releases/download/relay-latest/install.sh | sudo bash
```

It fits in beside what the server already runs, and keeps everything in `/opt/encore-relay`:

| The server has | The relay installs as |
| --- | --- |
| Docker and Pangolin | A container on Pangolin's network with no ports of its own. Publish it as a Pangolin resource (target `encore-relay`, port `8089`, authentication off: the relay checks its own tokens). |
| Docker and another proxy on 80/443 | A container on `127.0.0.1:8089` for that proxy. |
| Nothing on 80/443 | A service plus Caddy for HTTPS on a free `sslip.io` name. |

It prints the next steps and a short lab code. Run the same command to update; add `-s status` or
`-s uninstall` after `bash` to check on it or remove it (uninstalling touches nothing else).

Open the lab page on the device you want to test (a Tesla, a TV browser), enter the code, sign in with
Encore pairing, play something from Continue Watching, run the seek test, and copy the report.

To time a file from the server itself, with no browser:

```sh
docker exec encore-relay encore-relay bench -url 'https://…/file.mkv'
```

## Develop

```sh
go test ./...                       # needs ffmpeg; makes its own sample files
RELAY_SECRET=$(openssl rand -hex 24) RELAY_LAB_CODE=TEST-CODE RELAY_ALLOW_PRIVATE=1 go run ./cmd/encore-relay serve
```

`cmd/encore-relay/hls.min.js` is [hls.js](https://github.com/video-dev/hls.js) 1.5.17, Apache-2.0
(see `hls.LICENSE`).

## Not yet

- Converting video (HEVC, AV1, HDR) on a machine with a hardware encoder, as a last resort.
- HEVC and Dolby audio passed through untouched to Safari (needs fMP4 segments).
- Subtitle tracks from the file as WebVTT; scrub-bar thumbnails.
- Sending a segment to the browser while it is still being made.
