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
  const start = Date.now();
  let next = 0;
  let framesSent = 0;
  // Paced by the clock rather than one frame per timer tick: Windows timers
  // are too coarse for 33 ms.
  const timer = setInterval(() => {
    const due = Math.floor(((Date.now() - start) * opts.fps) / 1000) + 1;
    // Each video fragment goes out with the audio fragments before it.
    while (next < chunks.length && framesSent < due) {
      const chunk = chunks[next++];
      onData(chunk.data);
      if (chunk.hasVideo) framesSent++;
    }
    if (next >= chunks.length) {
      clearInterval(timer);
      onExit(0);
    }
  }, 5);
  return { kill: () => clearInterval(timer) };
}
