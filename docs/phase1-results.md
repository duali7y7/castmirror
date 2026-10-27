# Phase 1 results

Delay measured with the stopwatch photo method: open the stopwatch page on the PC, mirror the desktop to the TV, and take one photo that shows both. Delay = PC time minus TV time.

The `[tv]` lines in the sender's output give buffer, rtt, fps and stalls for each run.

## Setup

- Chromecast: 2nd gen (2015) "Living Room TV", firmware: _
- PC: Intel UHD 620 laptop on Wi-Fi
- Chromecast and PC on the same network: yes (192.168.178.x)
- Receiver: opened through DashCast (app ID 84912283), served over plain http from the PC

## Transport

- Does `ws://` work from the receiver page? Yes, when the page itself is plain http (the DashCast route). From the https GitHub Pages copy: not tested yet.
- The Cast library also starts on the page under DashCast, so the device shows "CastMirror" as the running app's status.

## What the Chromecast needs

- **Jumping to the live edge doesn't work on it.** Every seek restarts the hardware decoder from the previous keyframe (up to 2 s back with a 60-frame GOP). Decoding back up takes long enough that the receiver jumped again, so video never played (stuck on "Stream starting…", about 2 jumps a second).
- **Speeding up does work.** With `playbackRate` up to 1.25 to catch up, and no jumps, it plays smoothly.
- **The buffer floor is about 300 ms.** A 200 ms target ran dry (a stall in 35 s, readyState 2, couldn't keep up even at 1.25x). A 500 ms target settled at 310–400 ms with no stalls.
- **Sound stops once `playbackRate` changes**, and stays off after it returns to 1. The tone decoded (player volume 100%, device volume 95%) but wasn't heard until a run that never changed speed. So with sound it can't speed up either, and the delay stays at what it buffers before it starts playing: about 1.7–1.9 s with sound, 1.2–1.4 s without. Sound and picture come from the same stream and stay in sync.
- Defaults on the Chromecast are now: video only, a 350 ms target reached by speeding up (400 ms until the v1 tuning below); with sound, normal speed only. Either way, a jump only past target + 3 s.

## Runs

Desktop capture with ddagrab, x264 ultrafast, 1920x1080@30. The desktop was mostly still, so the real bitrate was 3–5 Mbps against the 8M cap.

| Source  | Bitrate | Audio | Target (ms) | Catch-up      | Buffer on TV (ms) | fps on TV | Stalls after start | Delay (photo) | Notes |
|---------|---------|-------|-------------|---------------|-------------------|-----------|--------------------|---------------|-------|
| desktop | 8M      | no    | 150         | jump at 600   | 150–1800          | 0         | many               |               | jump loop, never played |
| desktop | 8M      | no    | 2000        | none (rate 1) | 1210–1390         | 31        | 0 in 50 s          |               | holds the start-up buffer |
| desktop | 8M      | no    | 500         | speed only    | 310–450           | 30–33     | 0 in 90 s          |               | |
| desktop | 8M      | no    | 200         | speed only    | 210–600           | 30        | 1 in 35 s          |               | too low |
| desktop | 8M      | tone  | 400         | speed, jump at 3400 | 290–480     | 31–35     | 1 in 40 s          |               | stall and jump came from FFmpeg's tone input falling behind on the PC; no sound heard on the TV |
| desktop | 8M      | tone  | 2000        | none (rate 1) | 1720–1830         | 31        | 0                  |               | tone heard |
| desktop | 8M      | tone  | 1000 (default) | none, jump at 4000 | 1745–1900    | 29–31     | 0 in 30 s          | **1.93 s**    | new default with sound; photo: PC 33.423, TV 31.490 |

The measured delay is the TV's buffer (about 1.8 s) plus about 0.13 s for capture, encoding, Wi-Fi and display.

### v1 tuning (picture only, 27 Oct)

The first phone test had 2088 ms of buffer with sound, so v1 sends picture only. These runs picked the video-only target. Test pattern (`--source test`, 1920x1080@30, 6 Mbps), 130 s each, PC on Wi-Fi with an rtt of 8–33 ms:

| Target (ms) | Buffer on TV after catch-up (ms) | fps on TV | Stalls after start | Notes |
|-------------|----------------------------------|-----------|--------------------|-------|
| 300         | 143–391, mostly 200–320          | 27–33     | 0                  | |
| 350         | 164–351, mostly 190–340          | 30–32     | 0                  | chosen: same buffer as 300 in practice, a little more headroom for the phone's Wi-Fi |
| 400         | not run (the Chromecast went off the network) | | | |

The buffer sits below the target most of the time: the receiver only speeds up when it's more than 40 ms over, and the player drifts down from there. The catch-up from the 1.4–1.8 s start-up buffer took 5–10 s.

## Open questions

- Delay without sound wasn't photographed. From the buffer it should be about 0.5 s, but videos need sound, so it matters less.
- A long run with a real video file (`--source file`) for smoothness and lip sync.

## Decision

- [ ] Delay at or under ~500 ms and smooth, so go on to the iOS app (Phase 2)
- [ ] Over ~1 s, so re-plan around Cast Streaming
- [x] **Chosen: go on to Phase 2 with this approach at about 2 s.**

Result: 1.93 s with sound, smooth and in sync. That's over the ~1 s line, but what matters for watching videos is that sound and picture match, and they do, so the user chose to keep this approach. Cast Streaming (the protocol Chrome uses for tab mirroring) could get closer to 0.5 s with sound, but it's a much bigger build on the iPhone (encrypted RTP over UDP, Opus audio, retransmission).

What Phase 2 takes from this:
- The iPhone opens the receiver through DashCast and serves the page itself over plain http, with the WebSocket on the same phone.
- With sound, the receiver never changes speed on the Chromecast.
- The audio track must never have gaps (the receiver only plays as far as both tracks reach), so the phone fills silences with silent AAC.
