# Encore Relay

Prepares remote video files for web browsers, for [Encore Web](../Web/README.md). It never re-encodes
video. For each file a browser wants to play, it answers one of:

| Answer | When | What plays |
| --- | --- | --- |
| `direct` | MP4 with H.264 and AAC | The browser streams the source itself; the relay is not involved |
| `remux` | Matroska with H.264 | An HLS stream from the relay: video copied untouched, audio converted to AAC only if the browser can't decode it |
| `unsupported` | HEVC, AV1, HDR, 10-bit, no keyframe index | Nothing: the player picks another source (most titles have an H.264 release) |

## Why seeking is instant

A typical media server runs one long conversion and restarts it when you seek past what it has made.
The relay instead reads the file's keyframe index (Matroska Cues, a few hundred kilobytes fetched by
range) and lays out the whole stream before reading any media: every segment starts on a known
keyframe at a known byte offset. Any segment can then be made on its own:

1. Fetch the file from that segment's cluster offset (one ranged request).
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
GET    /v1/stats              counters (token required)
GET    /lab                   the lab page: time real titles on any device
```

Access is by signed, expiring tokens (`encore-relay token`); stream ids are unguessable. The relay
refuses to fetch private, loopback, and link-local addresses, checked at connection time so redirects
and DNS tricks are covered. It keeps no logs of what is played.

## Install on a server

On Ubuntu (Oracle Cloud free tier works, x86 or Arm):

```sh
curl -fsSL https://github.com/ivanxcc/Encore/releases/download/relay-latest/install.sh \
  | sudo ENCORE_CLOUD_URL=https://your-encore-cloud.workers.dev bash
```

It installs ffmpeg, the relay as a service, and Caddy for HTTPS, then prints the lab page's address
and a short lab code. Open the lab page on the device you want to test (a Tesla, a TV browser), enter
the code, sign in with Encore pairing, play something from Continue Watching, run the seek test, and
copy the report.

To time a file from the server itself, with no browser:

```sh
sudo -u encore-relay encore-relay bench -url 'https://…/file.mkv'
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
