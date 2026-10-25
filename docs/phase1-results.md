# Phase 1 results

Delay measured with the stopwatch photo method: open the stopwatch page on the PC, mirror the desktop to the TV, and take one photo that shows both. Delay = PC time minus TV time.

The `[tv]` lines in the sender's output give buffer, rtt, fps and stalls for each run.

## Setup

- Chromecast: 2nd gen (2015), firmware: _
- PC: Intel UHD 620 laptop, Wi-Fi / Ethernet: _
- Chromecast and PC on the same network: _

## Transport

- Does `ws://` work from the receiver page (no fallback to `cast`)? _

## Runs

| Source  | Size      | Bitrate | Encoder | Audio | Transport | Target (ms) | Delay (photo) | fps on TV | Stalls / min | Notes |
|---------|-----------|---------|---------|-------|-----------|-------------|---------------|-----------|--------------|-------|
| desktop | 1920x1080 | 6M      | x264    | no    |           | 150         |               |           |              |       |
| desktop | 1920x1080 | 8M      | x264    | no    |           | 150         |               |           |              |       |
| desktop | 1920x1080 | 10M     | x264    | no    |           | 150         |               |           |              |       |
| desktop | 1920x1080 | 8M      | x264    | tone  |           | 300         |               |           |              |       |
| file    | 1920x1080 | 8M      | x264    | yes   |           | 300         |               |           |              | 10 min smoothness run |

## Decision

- [ ] Delay at or under ~500 ms and smooth, so go on to the iOS app (Phase 2)
- [ ] Over ~1 s, so re-plan around Cast Streaming
