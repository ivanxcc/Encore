<p align="center">
  <img src="Encore/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="160" alt="Encore">
</p>

<h1 align="center">Encore</h1>

<p align="center">
  <strong>Your Stremio add-ons, presented like the Apple TV app.</strong><br>
  Native on Apple TV, iPhone, iPad, and Mac (Apple silicon and Intel).
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/ivanxcc/Encore?label=latest&color=4c5bd4" alt="Latest release"></a>
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
https://github.com/ivanxcc/Encore/releases/latest/download/altstore-source.json
```

Sideloadly works too: drag in `Encore-iOS-x.y.z.ipa`.

### Mac

The easiest way is one line in Terminal. It downloads the latest build, checks its SHA-256, installs it
to Applications, and opens it, with no "unidentified developer" prompt:

```sh
curl -fsSL https://github.com/ivanxcc/Encore/releases/latest/download/install-mac.sh | bash
```

Or open the DMG and drag Encore to Applications. Because the app is signed ad hoc rather than with an
Apple Developer ID, macOS blocks a browser-downloaded copy the first time: either run
`xattr -cr /Applications/Encore.app`, or open it once and approve it in **System Settings › Privacy &
Security › Open Anyway**.

**Updates install themselves.** On launch Encore checks for a newer release and offers **Update Now**.
It downloads the update itself (not through a browser, so macOS does not quarantine it), verifies its
checksum, swaps the app, and reopens. Gatekeeper never asks again after the first install. Removing the
first-install prompt too requires a $99/year Apple Developer ID to sign and notarize the app.

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

A household belongs to the Stremio account that signs in to it. Signing in with a different account
opens (or creates) that account's own household, so nothing ever mixes.

### With Encore Cloud (optional)

Turn on [Encore Cloud](#turn-on-encore-cloud) and households follow their Stremio account everywhere:

- **Every device matches.** Sign in to the household's Stremio account on any iPhone, iPad, Mac, or Apple
  TV and all of its profiles, their PINs, their Continue Watching and My List, and its playback settings
  appear. Edits on one device show up on the others.
- **Apple TV sign-in without a remote keyboard.** The TV shows a code; on your phone go to
  Settings › Encore Cloud › Sign In an Apple TV and type it.
- **Your households follow you.** The households you add (a sibling's shared household, or one with
  no Stremio account) appear on every device signed in to your *home* household's account, the first
  one you signed in to on that device (Settings › Households shows which). Removing one removes it
  everywhere.
- **Managing someone else's household.** Your sister signs in to her own Stremio account in Encore and
  taps Settings › Encore Cloud › Share This Household. You enter the code under Settings › Households ›
  Add a Shared Household. Her household (and its profiles) is now on your device too, and anything you
  change syncs back to hers. Your household is untouched.

A typical setup: one household for you and your partner (profiles Ivan, Will, TV), signed in to your
Stremio account; one household for your sister, signed in to hers and shared with you.

## Turn on Encore Cloud

Encore Cloud is a small Cloudflare Worker with a D1 database
([`Encore/Cloud`](Encore/Cloud)). Cloudflare's free plan is plenty. It stores each household's profiles
and history keyed to its Stremio account, and checks every request against Stremio, so there are no
separate passwords. One-time setup, about five minutes:

1. **Cloudflare account ID.** Sign in at [dash.cloudflare.com](https://dash.cloudflare.com). Open
   **Workers & Pages**. If asked, pick a `workers.dev` subdomain (any name). Copy the **Account ID** shown
   on the right side of that page.
2. **API token.** Click your profile icon › **My Profile › API Tokens › Create Token**. Choose the
   **Edit Cloudflare Workers** template, then **+ Add more** and add **Account › D1 › Edit**. Under
   Account Resources pick your account. Click **Continue to summary › Create Token** and copy the token.
3. **GitHub secrets.** In this repository go to **Settings › Secrets and variables › Actions › New
   repository secret** and add:
   - `CLOUDFLARE_API_TOKEN`: the token from step 2
   - `CLOUDFLARE_ACCOUNT_ID`: the ID from step 1
4. **Deploy.** Go to **Actions › Encore Cloud › Run workflow**. It creates the database, deploys the
   Worker, and shows the Worker's address in the run summary, for example
   `https://encore-cloud.<your-subdomain>.workers.dev`.
5. **Point the apps at it.** **Settings › Secrets and variables › Actions › Variables › New repository
   variable**: name `ENCORE_CLOUD_URL`, value the address from step 4.
6. **Release.** Run **Actions › Encore Release › Run workflow** (or push any change). Every app built from
   then on has Encore Cloud. Install the new build on each device; the Mac updates itself.

7. **Optional, recommended: cast photos, 4K artwork, and a smarter Home.** Create a free account at
   [themoviedb.org](https://www.themoviedb.org/signup), open **Settings › API**, request an API key
   (choose "Developer", any app name and URL), and copy the **API Read Access Token**. Add it as the
   repository secret `TMDB_API_KEY`, then run **Actions › Encore Cloud › Run workflow** again. Title
   pages then show the cast with photos, artwork comes in at original resolution (up to 4K), and the
   Home hero features what is trending this week. Without it, Encore uses Cinemeta's artwork and cast
   names.

Afterwards the Worker redeploys itself whenever `Encore/Cloud` changes. Without the variable, builds
simply have no cloud features, and everything else works the same.

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

## Releases: beta first, then everyone

Changes land on the **`beta`** branch. Every push there builds the three apps and publishes them as a
GitHub **pre-release** (`v0.2.0-beta.N`). Pre-releases are never the "latest" release, so nobody on the
stable channel is offered them; only beta installs are.

1. **Test the beta.** Beta Mac builds update themselves to each new beta. On a stable Mac, turn on
   Settings › About › **Beta Updates**, or install the newest beta with
   `curl -fsSL https://github.com/ivanxcc/Encore/releases/download/beta-channel/install-mac.sh | ENCORE_CHANNEL=beta bash`.
   iPhone, iPad, and Apple TV builds are on the beta release's page.
2. **Approve it.** **Actions › Promote to Stable › Run workflow** (works from the GitHub app on your
   phone too). It republishes the beta's exact files as the latest release, so stable Macs are offered
   the update and the AltStore source moves to it, and it moves `main` to the commit you tested.

Prefer an **Approve** button? Create an environment named `stable` (Settings › Environments) with
yourself as a required reviewer, and set the repository variable `ENCORE_RELEASE_APPROVAL` to `true`.
Every beta then waits for your approval (by email, in the GitHub app, or on the run page) and promotes
itself when you approve.

[`.github/workflows/encore-release.yml`](.github/workflows/encore-release.yml) does the building and
publishing; [`encore-promote.yml`](.github/workflows/encore-promote.yml) the promotion. To cut a named
version, bump `MARKETING_VERSION` in `Encore/project.yml`. [`encore-ci.yml`](.github/workflows/encore-ci.yml)
builds and tests every push, including an end-to-end run of the Mac updater's installer.

## Repository layout

```
Encore/                 the app (this is what ships)
  Packages/EncoreKit/   Stremio add-on protocol, account and library, ranking, households
  App/                  SwiftUI app for tvOS, iOS/iPadOS, and macOS
  Cloud/                Encore Cloud, the optional sync service (Cloudflare Worker + D1)
```

## Credits and license

Encore is based on [VortX](https://github.com/VortXTV/VortX) and is not affiliated with or endorsed by the
VortX project or Stremio. It works with the [Stremio](https://www.stremio.com) add-on ecosystem and plays
media with [libmpv](https://mpv.io) via [MPVKit](https://github.com/mpvkit/MPVKit). Licensed under the
GNU General Public License v3.0, the same as VortX; see [LICENSE](LICENSE). The original VortX sources
remain available in this repository's history and upstream.
