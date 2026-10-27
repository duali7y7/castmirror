# CastMirror

Low-delay mirroring of an iPhone screen and sound to a 2nd-gen (2015) Chromecast, at 1080p30.

**How it works:** the iPhone captures its screen with the iOS screen-broadcast feature and encodes H.264 in hardware. It sends one small MP4 fragment per frame over Wi-Fi. A custom receiver page on the Chromecast plays them with Media Source Extensions and stays pinned to the newest frame.

| Folder | What it is |
|---|---|
| `receiver/` | The Chromecast receiver page, published to GitHub Pages |
| `pc-sender/` | Phase 1 test sender: streams this PC to the Chromecast to measure the delay |
| `tools/stopwatch.html` | Millisecond clock for delay photos |
| `docs/phase1-results.md` | Delay measurements |
| `ios/` | The iPhone app: `CastMirrorCore` (encoders, muxer, Cast client, servers), the broadcast extension and a small container app |
| `castmirror.config.json` | Cast app ID and message namespace, shared by all parts |

## Status

- [x] Receiver page and PC test sender, tested in a desktop browser
- [x] Receiver tested on the Chromecast, through DashCast
- [x] Delay measured: 1.93 s with sound, in sync (see `docs/phase1-results.md`)
- [x] iPhone app: mirrors to the TV (first test on an iPhone 15, iOS 27)
- [ ] v1: picture only, lower delay, upright landscape, stats switch (built, to test on the phone)
- [ ] Own Cast app ID (optional while DashCast works)

## One-time setup

1. **GitHub:** see [How GitHub fits in](#how-github-fits-in).
2. **Google Cast developer registration** (one-time US$5, optional for now). Until there's an app ID, the sender uses [DashCast](https://github.com/madmod/dashcast), a public Cast app that opens any web page on the Chromecast. It opens the receiver page, served from this PC. That works, but it depends on someone else's app staying online, so registration is the long-term route:
   1. Go to the [Google Cast SDK Developer Console](https://cast.google.com/publish), sign in, and pay the registration fee.
   2. Choose **Add New Application → Custom Receiver**. Name it `CastMirror` and set the receiver URL to `https://duali7y7.github.io/castmirror/receiver/`.
   3. Copy the **Application ID** (8 characters) into `castAppId` in `castmirror.config.json`.
   4. Choose **Add New Device** and enter the Chromecast's serial number. It's printed on the Chromecast itself and on its box.
   5. Wait until the device shows as ready (about 15 minutes), then unplug the Chromecast and plug it back in.

## Phase 1: measure the delay from this PC

From `pc-sender/`:

```bash
npm install
```

```bash
npm run list
```

That command finds Chromecasts on the network. To stream the desktop:

```bash
npm start
```

With no app ID in `castmirror.config.json`, this launches DashCast on the TV (replacing whatever is playing) and points it at `http://<this PC>:8080/receiver/`. The TV then connects straight back to the PC on port 8765. Ctrl+C stops it and returns the TV to its home screen.

The first time, Windows asks whether Node.js may use the network: allow it on **private networks**. Otherwise the Chromecast can't reach the PC.

Useful variations:

```bash
npm start -- --bitrate 6M
```

```bash
npm start -- --audio --target 300
```

```bash
npm start -- --source file --file "C:\path\to\video.mp4"
```

Run `npm start -- --help` to see every option.

**To measure:** while the sender runs, open `http://localhost:8080/stopwatch.html` (or `https://duali7y7.github.io/castmirror/stopwatch.html`) full screen on the PC, and take one photo that shows the PC screen and the TV. The difference between the two clocks is the delay. The terminal prints the TV's own stats every 5 seconds (`[tv] ...` lines). Record the runs in `docs/phase1-results.md`.

**Testing without a Chromecast:** `npm run local` opens a local test server. Open the address it prints in Chrome.

**Receiver updates:** through DashCast, the TV loads the receiver from this PC, so edits apply on the next `npm start`. Through a registered app ID it loads from GitHub Pages, which can take up to 10 minutes to show changes because of caching.

## Install the iPhone app

The app is built unsigned on GitHub's Macs. Sideloadly signs it with your Apple ID and installs it from Windows. A free Apple ID works, but the app stops opening after 7 days until it's signed again.

One-time setup:
1. Install **iTunes** and **iCloud** from Apple's website (not the Microsoft Store versions), which Sideloadly needs to talk to the iPhone.
2. Install [Sideloadly](https://sideloadly.io).
3. On the iPhone: **Settings → Privacy & Security → Developer Mode**, turn it on, and let the phone restart. (The option appears after the first sideload attempt if it isn't there yet.)

Each install:
1. Download `CastMirror.ipa`. It's in the latest green **iOS app** run under **Actions → Artifacts → CastMirror-ipa** (a zip with the `.ipa` inside), or ask Claude to fetch it into `builds/`.
2. Plug the iPhone into the PC and tap **Trust** on the phone if asked.
3. Drag the `.ipa` into Sideloadly, enter your Apple ID, and click **Start**. Sideloadly asks for your Apple ID password itself.
4. The first time: on the iPhone, **Settings → General → VPN & Device Management**, tap your Apple ID and **Trust**.

Using it:
1. Open **CastMirror**. It searches for Chromecasts. Allow **Local Network** access when iOS asks; the broadcast needs it.
2. Tap the round button, then **Start Broadcast**. (Or long-press **Screen Recording** in Control Center and pick CastMirror.)
3. The TV switches to CastMirror. Open your video app. The picture reaches the TV about half a second after the phone. Sound plays from the phone: with sound in the stream, the Chromecast holds about 2 s of it and can't catch up (see `docs/phase1-results.md`), so v1 sends picture only.
4. To stop, tap the red indicator at the top of the screen and **Stop**.

Tips:
- **Show stats on the TV** in the app puts frame rate, buffer and network figures over the picture. It applies straight away while mirroring.
- The TV's **Game** picture mode cuts the TV's own processing time.

If something goes wrong:
- If the broadcast stops by itself, iOS shows the reason.
- Turn on **Show stats on the TV** to see the TV's stats and the last log lines.
- While a broadcast is running, open `http://localhost:8080/status` in Safari on the phone to see the phone's log, including the TV's stats every 5 seconds.

## How GitHub fits in

GitHub does three jobs:

1. **Stores the code.** This folder is a git repository, pushed to `github.com/duali7y7/castmirror`.
2. **Builds the iPhone app.** Only a Mac can build iPhone apps, so each push that touches `ios/` or `receiver/` runs `.github/workflows/ios.yml` on one of GitHub's free cloud Macs. It runs the core's tests, then produces the installable `.ipa`, plus `sample-stream`: 10 seconds of the app's stream format, which `npm start -- --source replay --file landscape-video.mp4` plays on the Chromecast from the PC. (`landscape.mp4` is the same with a test tone, for when sound comes back.)
3. **Hosts the receiver page.** Google requires a permanent HTTPS address for it, and GitHub Pages provides one (`.github/workflows/pages.yml`).

The repository is public, so build time and Pages hosting are free. Nothing in it is secret; the Cast app ID isn't secret either.

On github.com:
- **Code** tab: the files.
- **Actions** tab: every build and publish run, with a green tick (worked) or red cross (failed, with logs). Phase 2 builds put the `.ipa` under **Artifacts** at the bottom of the run.
- **Settings → Pages**: the receiver's address.
