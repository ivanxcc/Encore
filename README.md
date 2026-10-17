<p align="center">
  <img src="Encore/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="160" alt="Encore">
</p>

<h1 align="center">Encore</h1>

<p align="center">
  <strong>Your Stremio add-ons, presented like the Apple TV app.</strong><br>
  Native on Apple TV, iPhone, iPad, and Mac (Apple silicon and Intel).
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/ivanxcc/VortX?label=latest&color=4c5bd4" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/platforms-tvOS%20%C2%B7%20iOS%20%C2%B7%20iPadOS%20%C2%B7%20macOS-4c5bd4" alt="Platforms">
  <img src="https://img.shields.io/badge/license-GPL--3.0-4c5bd4" alt="License">
</p>

---

Encore is a personal fork of [VortX](https://github.com/VortXTV/VortX), rebuilt around three ideas:

1. **It builds from public code only.** VortX depends on a private engine. Encore talks to Stremio add-ons
   and the Stremio account directly with a small Swift package (`EncoreKit`), and plays video with the
   public [MPVKit](https://github.com/mpvkit/MPVKit). Anyone can build it, and every release is produced
   by GitHub Actions from this repository.
2. **It looks and feels like the Apple TV app.** Full-bleed artwork, shelves, a featured hero, the real
   tvOS focus engine, and one design system that adapts to the TV, the phone, and the Mac.
3. **It plays at full quality, and gives up gracefully.** Match frame rate and dynamic range on Apple TV
   4K, HDR10 / HLG output, lossless audio decoded to up to 7.1, and a bounded source failover that ends on a
   clear message instead of retrying forever.

## Download

Every build is on the **[Releases page](../../releases/latest)**:

| File | For |
| --- | --- |
| `Encore-tvOS-x.y.z.ipa` | Apple TV (tvOS 18 or later) |
| `Encore-iOS-x.y.z.ipa` | iPhone and iPad (iOS 18 or later) |
| `Encore-macOS-x.y.z.dmg` | Mac, Apple silicon and Intel (macOS 15 or later) |
| `altstore-source.json` | AltStore / SideStore source for automatic iPhone and iPad updates |

The apps are not on the App Store, so iPhone, iPad, and Apple TV need the IPA signed with your Apple ID
when you install it. A free Apple ID lasts 7 days per install (just re-install, nothing is lost); a paid
developer account lasts a year.

### Apple TV: Sideloadly

1. Install [Sideloadly](https://sideloadly.io) on a Mac or Windows PC on the same network as the Apple TV.
2. On the Apple TV open **Settings › Remotes and Devices › Remote App and Devices** and leave it open.
3. In Sideloadly, pick the Apple TV (it appears as a network device) and pair with the code shown.
4. Drag `Encore-tvOS-x.y.z.ipa` in, enter your Apple ID, press **Start**.

Or with Xcode: **Window › Devices and Simulators**, pair the Apple TV, and drag the IPA onto it.

### iPhone and iPad: AltStore or SideStore (auto-updating)

Add this source in AltStore or SideStore, then install Encore from it. New releases show up as updates:

```
https://github.com/ivanxcc/VortX/releases/latest/download/altstore-source.json
```

Sideloadly works too: drag in `Encore-iOS-x.y.z.ipa`.

### Mac

Open the DMG and drag Encore to Applications. The app is signed ad hoc rather than with a Developer ID,
so clear the download quarantine once:

```sh
xattr -cr /Applications/Encore.app
```

## First run

1. **Sign in to Stremio** (Settings › Stremio Account). Your add-ons, library, and progress come with it.
   Without an account Encore starts with Cinemeta for browsing; add stream add-ons under Settings › Add-ons.
2. **Apple TV 4K:** turn on **Settings › Video and Audio › Match Content › Match Dynamic Range** and
   **Match Frame Rate** in tvOS. Encore then plays each title at its own frame rate and in HDR10 / HLG /
   Dolby Vision.
3. **Torrents** play through a Stremio streaming server (Stremio Service on a computer or NAS). Enter its
   address in Settings › Streaming Server. Debrid and direct sources never need it.

## Households and profiles

A **household** is one person's (or one family's) Stremio account, add-ons, profiles, and watch history,
stored in its own folder and its own Keychain space. Households never share or sync anything with each
other, so a sibling or roommate gets their own household instead of merging into yours. Switch from the
"Who's watching?" screen or Settings › Household; it is instant.

**Profiles** live inside a household. The main profile uses the Stremio account's library; other profiles
keep their own Continue Watching and list. Profiles can have a PIN and a Kids flag.

## Picture and sound

- **Match Content:** frame rate and dynamic range switching on Apple TV (system setting required, above).
- **HDR:** HDR10 and HLG are output as HDR, never tone mapped on an HDR TV. EDR on iPhone, iPad, and Mac.
- **Audio:** Dolby TrueHD and DTS-HD MA are decoded on device to uncompressed multichannel PCM, up to 7.1.
  Dolby Digital Plus with Atmos in MP4 / HLS sources is passed through by the system player.
- **Source choice:** cached debrid and direct links first, then quality up to your cap, preferring REMUX,
  lossless audio, Atmos, and 7.1. The source list shows exactly what each option is.
- **Info line:** the libmpv player shows what is really being decoded and output.
- **Coming next:** on-the-fly MKV remux into the system player for true Dolby Vision signalling and Atmos
  passthrough from MKV files.

## Building it yourself

```sh
brew install xcodegen
cd Encore && xcodegen generate && open Encore.xcodeproj
```

Pick `Encore-tvOS`, `Encore-iOS`, or `Encore-macOS`, set your signing team, and run. The engine's tests run
anywhere Swift runs: `cd Encore/Packages/EncoreKit && swift test`. See [Encore/README.md](Encore/README.md)
for the architecture.

## Releases are automatic

[`.github/workflows/encore-release.yml`](.github/workflows/encore-release.yml) runs on every push to `main`
that touches `Encore/`, and on any `v*` tag. It builds the three apps, verifies the Mac app is universal,
writes the AltStore / SideStore source, and publishes a GitHub Release with notes generated from the
commits. To cut a named version, bump `MARKETING_VERSION` in `Encore/project.yml` or push a tag such as
`v0.2.0`. [`.github/workflows/encore-ci.yml`](.github/workflows/encore-ci.yml) builds and tests every push.

## Repository layout

```
Encore/                 the app (this is what ships)
  Packages/EncoreKit/   Stremio add-on protocol, account and library, ranking, households
  App/                  SwiftUI app for tvOS, iOS/iPadOS, and macOS
app/, android/, ...     the original VortX sources this fork started from (not built or shipped)
```

## Credits and license

Encore is based on [VortX](https://github.com/VortXTV/VortX) and is not affiliated with or endorsed by the
VortX project or Stremio. It works with the [Stremio](https://www.stremio.com) add-on ecosystem and plays
media with [libmpv](https://mpv.io) via [MPVKit](https://github.com/mpvkit/MPVKit). Licensed under the
GNU General Public License v3.0, the same as VortX; see [LICENSE](LICENSE) and
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
