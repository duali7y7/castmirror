// Plays a recorded CastMirror stream (an init segment then fragments, as the
// iOS app's tests save it) at its frame rate, so the iPhone muxer's output
// can be checked on a real Chromecast without the phone.

import fs from 'node:fs';
import { FragmentSplitter } from './mp4.js';

// Same shape as startFfmpeg: calls onData with the stream's bytes and onExit
// at the end, and returns something with kill().
export function startReplay(opts, onData, onExit) {
  if (!opts.file) throw new Error('--source replay needs --file <recorded stream>');
  const chunks = new FragmentSplitter().push(fs.readFileSync(opts.file));
  let next = 0;
  const timer = setInterval(() => {
    // Everything up to and including the next video fragment; the audio
    // fragments in between go with it.
    while (next < chunks.length) {
      const chunk = chunks[next++];
      onData(chunk.data);
      if (chunk.hasVideo) break;
    }
    if (next >= chunks.length) {
      clearInterval(timer);
      onExit(0);
    }
  }, 1000 / opts.fps);
  return { kill: () => clearInterval(timer) };
}
