// Splits a fragmented-MP4 byte stream (FFmpeg's `empty_moov+frag_every_frame`
// output) into the chunks the receiver appends: one init segment (ftyp+moov)
// and then one moof+mdat fragment per frame. Also tells keyframes apart so the
// sender can drop frames cleanly when the network backs up.
//
// The iOS muxer produces the same layout, so this file doubles as the
// reference for its box handling.

const SAMPLE_IS_NON_SYNC = 0x00010000;

function readBoxes(buf, start, end) {
  const boxes = [];
  let pos = start;
  while (pos + 8 <= end) {
    let size = buf.readUInt32BE(pos);
    let header = 8;
    if (size === 1) {
      size = Number(buf.readBigUInt64BE(pos + 8));
      header = 16;
    } else if (size === 0) {
      size = end - pos;
    }
    if (size < header || pos + size > end) break;
    boxes.push({ type: buf.toString('latin1', pos + 4, pos + 8), body: pos + header, end: pos + size });
    pos += size;
  }
  return boxes;
}

function childBoxes(buf, box, type) {
  return readBoxes(buf, box.body, box.end).filter((b) => b.type === type);
}

function childBox(buf, box, type) {
  return childBoxes(buf, box, type)[0];
}

function rootBox(buf) {
  return { type: 'root', body: 0, end: buf.length };
}

// Returns the video track's ID and its trex default sample flags.
export function parseInit(init) {
  const result = { videoTrackId: -1, defaultFlags: 0 };
  const moov = childBox(init, rootBox(init), 'moov');
  if (!moov) return result;

  for (const trak of childBoxes(init, moov, 'trak')) {
    const tkhd = childBox(init, trak, 'tkhd');
    const mdia = childBox(init, trak, 'mdia');
    const hdlr = mdia && childBox(init, mdia, 'hdlr');
    if (!tkhd || !hdlr) continue;
    // hdlr: version/flags(4) pre_defined(4) handler_type(4)
    if (init.toString('latin1', hdlr.body + 8, hdlr.body + 12) !== 'vide') continue;
    // tkhd: version/flags(4), creation+modification (8 or 16), track_ID(4)
    const version = init[tkhd.body];
    result.videoTrackId = init.readUInt32BE(tkhd.body + 4 + (version === 1 ? 16 : 8));
  }

  const mvex = childBox(init, moov, 'mvex');
  if (mvex) {
    for (const trex of childBoxes(init, mvex, 'trex')) {
      // trex: version/flags(4) track_ID(4) desc_index(4) duration(4) size(4) flags(4)
      if (init.readUInt32BE(trex.body + 4) === result.videoTrackId) {
        result.defaultFlags = init.readUInt32BE(trex.body + 20);
      }
    }
  }
  return result;
}

// Returns { hasVideo, keyframe } for one moof+mdat fragment.
export function inspectFragment(frag, initInfo) {
  const moof = childBox(frag, rootBox(frag), 'moof');
  if (!moof) return { hasVideo: false, keyframe: false };

  for (const traf of childBoxes(frag, moof, 'traf')) {
    const tfhd = childBox(frag, traf, 'tfhd');
    if (!tfhd || frag.readUInt32BE(tfhd.body + 4) !== initInfo.videoTrackId) continue;

    // tfhd optional fields, in order: base_data_offset(8) sample_description_index(4)
    // default_sample_duration(4) default_sample_size(4) default_sample_flags(4)
    const tfhdFlags = frag.readUInt32BE(tfhd.body) & 0xffffff;
    let flags = initInfo.defaultFlags;
    let pos = tfhd.body + 8;
    if (tfhdFlags & 0x1) pos += 8;
    if (tfhdFlags & 0x2) pos += 4;
    if (tfhdFlags & 0x8) pos += 4;
    if (tfhdFlags & 0x10) pos += 4;
    if (tfhdFlags & 0x20) flags = frag.readUInt32BE(pos);

    const trun = childBox(frag, traf, 'trun');
    if (trun) {
      // trun: version/flags(4) sample_count(4) [data_offset(4)] [first_sample_flags(4)]
      // then per sample: [duration(4)] [size(4)] [flags(4)] [composition offset(4)]
      const trunFlags = frag.readUInt32BE(trun.body) & 0xffffff;
      let p = trun.body + 8;
      if (trunFlags & 0x1) p += 4;
      if (trunFlags & 0x4) {
        flags = frag.readUInt32BE(p);
      } else if (trunFlags & 0x400) {
        if (trunFlags & 0x100) p += 4;
        if (trunFlags & 0x200) p += 4;
        flags = frag.readUInt32BE(p);
      }
    }
    return { hasVideo: true, keyframe: (flags & SAMPLE_IS_NON_SYNC) === 0 };
  }
  return { hasVideo: false, keyframe: false };
}

export class FragmentSplitter {
  constructor() {
    this.buf = Buffer.alloc(0);
    this.pending = [];
    this.initInfo = { videoTrackId: -1, defaultFlags: 0 };
  }

  // Feed raw bytes; returns the chunks completed by them.
  push(data) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, data]) : data;
    const chunks = [];
    while (this.buf.length >= 8) {
      let size = this.buf.readUInt32BE(0);
      if (size === 1) {
        if (this.buf.length < 16) break;
        size = Number(this.buf.readBigUInt64BE(8));
      }
      if (size < 8) throw new Error('corrupt MP4 stream (box size ' + size + ')');
      if (this.buf.length < size) break;

      const type = this.buf.toString('latin1', 4, 8);
      this.pending.push(this.buf.subarray(0, size));
      this.buf = this.buf.subarray(size);

      if (type === 'moov') {
        const init = Buffer.concat(this.pending);
        this.pending = [];
        this.initInfo = parseInit(init);
        chunks.push({ kind: 'init', data: init, keyframe: false, hasVideo: false });
      } else if (type === 'mdat') {
        const frag = Buffer.concat(this.pending);
        this.pending = [];
        const info = inspectFragment(frag, this.initInfo);
        chunks.push({ kind: 'fragment', data: frag, keyframe: info.keyframe, hasVideo: info.hasVideo });
      } else if (type === 'cmau') {
        // Separate sound (see pcm.js), recorded between fragments.
        chunks.push({ kind: 'audio', data: this.pending.pop(), keyframe: false, hasVideo: false });
      }
    }
    return chunks;
  }
}
