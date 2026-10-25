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
- Defaults on the Chromecast are now: video only, a 400 ms target reached by speeding up; with sound, normal speed only. Either way, a jump only past target + 3 s.

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

## Open questions

- Delay without sound wasn't photographed. From the buffer it should be about 0.5 s, but videos need sound, so it matters less.
- A long run with a real video file (`--source file`) for smoothness and lip sync.

## Decision

- [ ] Delay at or under ~500 ms and smooth, so go on to the iOS app (Phase 2)
- [ ] Over ~1 s, so re-plan around Cast Streaming

Result: 1.93 s with sound, smooth and in sync. That's over the ~1 s line, but what matters for watching videos is that sound and picture match, and they do. Cast Streaming (the protocol Chrome uses for tab mirroring) could get closer to 0.5 s with sound, but it's a much bigger build on the iPhone (encrypted RTP over UDP, Opus audio, retransmission). Waiting for the user's call.
