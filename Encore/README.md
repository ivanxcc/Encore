# Encore

A native Apple TV, iPhone, iPad, and Mac app for the Stremio add-on ecosystem, designed after the
Apple TV app. User-facing docs and install steps are in the [repository README](../README.md).

## Why it builds without anything private

Stremio add-ons, accounts, and libraries are plain HTTPS + JSON. `Packages/EncoreKit` implements that
protocol in pure Swift, so there is no Rust engine, no FFI, and no private repository. The only
third-party dependency is [MPVKit](https://github.com/mpvkit/MPVKit) (libmpv) for files AVFoundation
can't open. Every piece ships for Apple silicon and Intel.

```
Encore/
  Packages/EncoreKit/   the engine: add-on protocol, Stremio account + library, ranking,
                         households and profiles. Tested on Linux CI (swift test).
  App/                   one SwiftUI app for tvOS, iOS/iPadOS, and macOS
    Design/              Apple TV design system: theme, cards, shelves, focus styles, image pipeline
    Screens/             Home, Detail, Search, Library, Settings, Households, Profiles
    Player/              AVKit engine + libmpv engine behind one bounded failover plan
  project.yml            XcodeGen spec (three targets, one source tree)
```

## Build

```sh
brew install xcodegen
cd Encore && xcodegen generate && open Encore.xcodeproj
```

Pick the `Encore-tvOS`, `Encore-iOS`, or `Encore-macOS` scheme, set your signing team, and run.
CI (`.github/workflows/encore.yml`) runs the engine tests and builds all three apps unsigned; the
universal Mac app is uploaded as a build artifact.

## Households and profiles

A **household** is a separate directory plus a separate Keychain namespace holding one Stremio account,
its add-ons, profiles, and watch history. Nothing is shared between households, so a sibling or a
roommate gets their own household instead of merging into yours. Switching is instant.

**Profiles** live inside a household. The main profile uses the Stremio account's library (so it stays in
step with Stremio everywhere); other profiles keep their own Continue Watching and list on the device.

## Playback reliability

`PlaybackPlan` (in EncoreKit, unit tested) decides the whole retry story up front: the best ranked
source first (cached debrid and direct links beat torrents that still need peers), the native player
for MP4/HLS with libmpv as the same-URL fallback, libmpv directly for MKV, and at most three sources.
A dead title ends on a clear message in about a minute instead of retrying forever.

## Torrents

Torrent sources play through a Stremio streaming server (Stremio Service on a Mac, PC, or NAS). Set its
address in Settings → Streaming Server. Debrid and direct sources never need it.

## Picture and sound (Apple TV 4K)

- **Match Content**: each title plays at its own frame rate and in Dolby Vision / HDR10 / HLG. Also turn on
  tvOS Settings › Video and Audio › Match Content (both switches).
- **HDR from libmpv**: PQ/HLG output into a correctly tagged layer, never tone mapped on an HDR TV.
- **Audio**: TrueHD and DTS-HD MA are decoded on device to uncompressed multichannel PCM (up to 7.1), the
  same approach Infuse uses on Apple TV. Dolby Digital Plus with Atmos in MP4/HLS is passed through.
- **Next**: on-the-fly MKV → HLS remux into the native player, for true Dolby Vision signalling and DD+
  Atmos passthrough from MKV files.
