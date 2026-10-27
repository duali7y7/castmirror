// Sound sent apart from the video, the way the iPhone app sends it with "TV,
// low delay": 'cmau' chunks shaped like MP4 boxes, so the same splitters
// carry them, holding 16-bit stereo PCM at 48 kHz:
//   u32 size, 'cmau', u64 first sample (48 kHz, from the stream's start),
//   then little-endian samples, left and right interleaved.
// The receiver plays them with Web Audio, lined up with the video by the
// sample number (see AudioOut in receiver/receiver.js).

export const PCM_RATE = 48000;
export const PCM_HEADER = 16;
const BYTES_PER_FRAME = 4;

export function pcmChunk(firstSample, samples) {
  const chunk = Buffer.alloc(PCM_HEADER + samples.length);
  chunk.writeUInt32BE(chunk.length, 0);
  chunk.write('cmau', 4, 'latin1');
  chunk.writeBigUInt64BE(BigInt(firstSample), 8);
  samples.copy(chunk, PCM_HEADER);
  return chunk;
}

// Cuts a raw s16le stereo byte stream into chunks of `frames` frames (20 ms
// by default), numbering samples from the start of the stream.
export class PcmPacker {
  constructor(frames = 960) {
    this.chunkBytes = frames * BYTES_PER_FRAME;
    this.buf = Buffer.alloc(0);
    this.nextSample = 0;
  }

  push(data) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, data]) : data;
    const chunks = [];
    while (this.buf.length >= this.chunkBytes) {
      chunks.push(pcmChunk(this.nextSample, this.buf.subarray(0, this.chunkBytes)));
      this.nextSample += this.chunkBytes / BYTES_PER_FRAME;
      this.buf = this.buf.subarray(this.chunkBytes);
    }
    return chunks;
  }
}
