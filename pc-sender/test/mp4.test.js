import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

import { buildFfmpegArgs } from '../src/ffmpeg.js';
import { FragmentSplitter } from '../src/mp4.js';

function encodeSample({ audio }) {
  const args = buildFfmpegArgs({
    source: 'test', width: 640, height: 360, fps: 30, bitrate: '1M', gop: 15,
    encoder: 'x264', preset: 'ultrafast', audio,
  }).filter((a) => a !== '-re');
  // Two seconds is enough: the output is otherwise endless.
  args.splice(args.indexOf('-map'), 0, '-t', '2');
  return execFileSync('ffmpeg', args, { maxBuffer: 64 * 1024 * 1024 });
}

function splitAll(bytes, pieceSize) {
  const splitter = new FragmentSplitter();
  const chunks = [];
  for (let i = 0; i < bytes.length; i += pieceSize) {
    chunks.push(...splitter.push(bytes.subarray(i, i + pieceSize)));
  }
  return chunks;
}

test('splits FFmpeg output into an init segment and one fragment per frame', () => {
  const chunks = splitAll(encodeSample({ audio: false }), 4096);
  assert.equal(chunks[0].kind, 'init');
  assert.equal(chunks[0].data.toString('latin1', 4, 8), 'ftyp');

  const frags = chunks.slice(1);
  assert.ok(frags.every((c) => c.kind === 'fragment' && c.hasVideo));
  assert.ok(frags.length >= 58 && frags.length <= 60, `got ${frags.length} fragments`);
});

test('marks a keyframe every GOP', () => {
  const frags = splitAll(encodeSample({ audio: false }), 65536).slice(1);
  const keyIndexes = frags.map((c, i) => (c.keyframe ? i : -1)).filter((i) => i >= 0);
  assert.deepEqual(keyIndexes.slice(0, 4), [0, 15, 30, 45]);
});

test('finds the video track when audio is muxed in', () => {
  const chunks = splitAll(encodeSample({ audio: true }), 1000);
  const video = chunks.slice(1).filter((c) => c.hasVideo);
  assert.ok(video[0].keyframe, 'first video fragment is a keyframe');
  assert.ok(video.length >= 58 && video.length <= 60, `got ${video.length} video fragments`);
  const keyIndexes = video.map((c, i) => (c.keyframe ? i : -1)).filter((i) => i >= 0);
  assert.deepEqual(keyIndexes.slice(0, 4), [0, 15, 30, 45]);
});
