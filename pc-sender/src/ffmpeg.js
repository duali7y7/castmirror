// Builds the FFmpeg command that captures (or plays) video, encodes H.264 the
// way the 2015 Chromecast can decode it, and writes fragmented MP4 to stdout
// with one fragment per frame.

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

// FFMPEG_PATH wins; otherwise use winget's install location when this process
// started before winget added it to PATH.
function ffmpegPath() {
  if (process.env.FFMPEG_PATH) return process.env.FFMPEG_PATH;
  if (process.platform === 'win32' && process.env.LOCALAPPDATA) {
    const winget = path.join(process.env.LOCALAPPDATA, 'Microsoft', 'WinGet', 'Links', 'ffmpeg.exe');
    if (fs.existsSync(winget)) return winget;
  }
  return 'ffmpeg';
}

export function buildFfmpegArgs(opts) {
  const { source, width, height, fps, bitrate, gop } = opts;
  const args = ['-hide_banner', '-loglevel', 'warning', '-nostats'];
  let audioInput = -1;

  if (source === 'desktop') {
    if (opts.capture === 'gdigrab') {
      args.push('-f', 'gdigrab', '-framerate', String(fps), '-draw_mouse', '1', '-i', 'desktop');
    } else {
      args.push('-f', 'lavfi', '-i',
        `ddagrab=output_idx=${opts.monitor}:framerate=${fps}:draw_mouse=1,hwdownload,format=bgra`);
    }
  } else if (source === 'test') {
    args.push('-re', '-f', 'lavfi', '-i', `testsrc2=size=${width}x${height}:rate=${fps}`);
  } else if (source === 'file') {
    if (!opts.file) throw new Error('--source file needs --file <path>');
    args.push('-re', '-stream_loop', '-1', '-i', opts.file);
  } else {
    throw new Error('unknown source ' + source);
  }

  if (opts.audio && source !== 'file') {
    args.push('-re', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000');
    audioInput = 1;
  }

  args.push('-map', '0:v:0');
  if (source === 'file') args.push('-map', '0:a:0?');
  else if (audioInput >= 0) args.push('-map', `${audioInput}:a:0`);

  const pixFmt = opts.encoder === 'qsv' ? 'nv12' : 'yuv420p';
  args.push('-vf', [
    `fps=${fps}`,
    `scale=${width}:${height}:force_original_aspect_ratio=decrease`,
    `pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2`,
    `format=${pixFmt}`,
  ].join(','));

  // No B-frames, so every frame can be shown as soon as it arrives.
  const rate = ['-b:v', bitrate, '-maxrate', bitrate, '-bufsize', halfBitrate(bitrate)];
  if (opts.encoder === 'qsv') {
    args.push('-c:v', 'h264_qsv', '-preset', 'veryfast', '-profile:v', 'high', '-level', '41',
      '-bf', '0', '-g', String(gop), '-look_ahead', '0', '-async_depth', '1', ...rate);
  } else {
    args.push('-c:v', 'libx264', '-preset', opts.preset, '-tune', 'zerolatency',
      '-profile:v', 'high', '-level:v', '4.1', '-bf', '0', '-g', String(gop), ...rate);
  }

  if (source === 'file' || audioInput >= 0) {
    args.push('-c:a', 'aac', '-b:a', '128k', '-ar', '48000', '-ac', '2');
  }

  // One fragment per video frame, with that frame's audio in the same
  // fragment. (frag_every_frame also cuts at every audio packet and writes
  // broken audio durations.)
  args.push(
    '-f', 'mp4',
    '-movflags', 'empty_moov+default_base_moof+frag_keyframe',
    '-frag_duration', String(Math.floor(1e6 / fps)),
    '-flush_packets', '1',
    'pipe:1',
  );
  return args;
}

function halfBitrate(bitrate) {
  const m = /^(\d+(?:\.\d+)?)([kKmM]?)$/.exec(bitrate);
  if (!m) return bitrate;
  return String(parseFloat(m[1]) / 2) + m[2];
}

export function startFfmpeg(opts, onData, onExit) {
  const args = buildFfmpegArgs(opts);
  const proc = spawn(ffmpegPath(), args, { stdio: ['ignore', 'pipe', 'pipe'] });
  proc.stdout.on('data', onData);
  proc.stderr.on('data', (d) => {
    for (const line of d.toString().split(/\r?\n/)) {
      if (line.trim()) console.log('[ffmpeg] ' + line);
    }
  });
  proc.on('error', (e) => console.log('[ffmpeg] failed to start: ' + e.message));
  proc.on('exit', (code, signal) => onExit(code, signal));
  return proc;
}
