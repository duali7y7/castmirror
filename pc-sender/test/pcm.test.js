import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import net from 'node:net';

import { buildFfmpegArgs } from '../src/ffmpeg.js';
import { FragmentSplitter } from '../src/mp4.js';
import { PCM_HEADER, PcmPacker, pcmChunk } from '../src/pcm.js';

test('a sound chunk is a cmau box with its first sample and the samples', () => {
  const samples = Buffer.from([1, 0, 2, 0, 3, 0, 4, 0]);
  const chunk = pcmChunk(2 ** 33 + 5, samples);
  assert.equal(chunk.readUInt32BE(0), chunk.length);
  assert.equal(chunk.toString('latin1', 4, 8), 'cmau');
  assert.equal(chunk.readBigUInt64BE(8), BigInt(2 ** 33 + 5));
  assert.deepEqual(chunk.subarray(PCM_HEADER), samples);
});

test('the packer cuts 20 ms chunks and numbers their samples', () => {
  const packer = new PcmPacker();
  const chunks = [...packer.push(Buffer.alloc(3000)), ...packer.push(Buffer.alloc(5000))];
  assert.equal(chunks.length, 2); // 8000 bytes = 2000 frames = two chunks of 960
  assert.deepEqual(chunks.map((c) => Number(c.readBigUInt64BE(8))), [0, 960]);
  assert.ok(chunks.every((c) => c.length === PCM_HEADER + 960 * 4));
});

test('the MP4 splitter passes sound chunks through on their own', () => {
  const chunk = pcmChunk(960, Buffer.alloc(16));
  const out = new FragmentSplitter().push(Buffer.concat([chunk.subarray(0, 10), chunk.subarray(10)]));
  assert.equal(out.length, 1);
  assert.equal(out[0].kind, 'audio');
  assert.deepEqual(out[0].data, chunk);
});

test('with separate sound the MP4 is picture only and the sound goes to its own output', () => {
  const args = buildFfmpegArgs({
    source: 'synctest', width: 640, height: 360, fps: 30, bitrate: '1M', gop: 15,
    encoder: 'x264', preset: 'ultrafast', pcmUrl: 'tcp://127.0.0.1:1',
  });
  const mp4End = args.indexOf('pipe:1');
  assert.ok(!args.slice(0, mp4End).includes('aac'));
  assert.deepEqual(args.slice(mp4End + 1), ['-map', '1:a:0', '-c:a', 'pcm_s16le', '-ar', '48000', '-ac', '2',
    '-f', 's16le', '-flush_packets', '1', 'tcp://127.0.0.1:1']);
});

test('the sync test beeps for the first 100 ms of each second', async () => {
  const pcm = [];
  const server = net.createServer((sock) => sock.on('data', (d) => pcm.push(d)));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const args = buildFfmpegArgs({
    source: 'synctest', width: 320, height: 180, fps: 30, bitrate: '500k', gop: 15,
    encoder: 'x264', preset: 'ultrafast', pcmUrl: `tcp://127.0.0.1:${server.address().port}`,
  }).filter((a) => a !== '-re');
  // Both inputs are endless; stop each after 1.5 s so both outputs end.
  for (let i = args.length - 1; i >= 0; i--) if (args[i] === '-i') args.splice(i, 0, '-t', '1.5');
  const proc = spawn('ffmpeg', args, { stdio: ['ignore', 'ignore', 'inherit'] });
  const timer = setTimeout(() => proc.kill(), 30000);
  const code = await new Promise((resolve) => proc.on('exit', resolve));
  clearTimeout(timer);
  server.close();
  assert.equal(code, 0);

  const all = Buffer.concat(pcm);
  const loudness = (fromMs, toMs) => {
    let peak = 0;
    for (let f = (fromMs * 48) | 0; f < (toMs * 48) | 0 && f * 4 < all.length; f++) {
      peak = Math.max(peak, Math.abs(all.readInt16LE(f * 4)));
    }
    return peak;
  };
  assert.ok(all.length >= 1.4 * 48000 * 4, `got ${all.length} bytes of sound`);
  assert.ok(loudness(5, 95) > 10000, 'beep at the start of the first second');
  assert.equal(loudness(110, 990), 0, 'silent for the rest of the second');
  assert.ok(loudness(1005, 1095) > 10000, 'beep at the start of the next second');
});
