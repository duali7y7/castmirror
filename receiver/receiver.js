// CastMirror receiver: plays a live fragmented-MP4 stream with Media Source
// Extensions and keeps playback pinned to the newest frame.
//
// Media arrives as complete MP4 chunks: one init segment (ftyp+moov), then one
// moof+mdat fragment per frame. Sound comes either inside that stream or
// apart from it, as 'cmau' chunks of raw PCM played with Web Audio (see
// AudioOut). Two transports carry them:
//   ws   - binary WebSocket frames straight from the sender (lowest overhead)
//   cast - base64 pieces over the Cast channel, for when the Chromecast blocks
//          ws:// from an https page
// Control messages are JSON on the custom namespace (or WebSocket text frames).
//
// Written without newer syntax (?., ??) because the 2015 Chromecast runs an
// older Chromium.
(function () {
  'use strict';

  const NS = 'urn:x-cast:com.castmirror.v1';
  const CAF_URL = 'https://www.gstatic.com/cast/sdk/libs/caf_receiver/v3/cast_receiver_framework.js';
  const params = new URLSearchParams(location.search);
  const isCast = /CrKey/.test(navigator.userAgent);
  // ?ws=ws://host:port connects straight to the sender instead of waiting for
  // a hello over the Cast channel. Browser test mode works this way, and so
  // does the sender's DashCast mode, which opens this page through another
  // Cast app.
  const directWs = params.get('ws');

  // Seconds of buffer to aim for, and how far behind to jump straight to the
  // edge. Null means pick by device and stream: desktop Chrome's audio
  // renderer stalls below ~300 ms, while video alone plays smoothly at
  // ~150 ms. The 2015 Chromecast runs dry below ~300 ms, and every jump
  // restarts its hardware decoder from the previous keyframe, so there it
  // catches up by playing faster and jumps only when far behind. With sound
  // it can't play faster either (see canChangeRate), so the delay stays at
  // what it buffers on start-up, about 1.7 s.
  const config = {
    targetLag: num(params.get('target'), null),
    jumpLag: num(params.get('jump'), null),
    maxRate: num(params.get('rate'), 1.25),
    // Separate sound plays this many ms later than the video says (+) or
    // earlier (-), to line up with the picture on the TV.
    avOffset: num(params.get('avoffset'), 0) / 1000,
  };

  function targetLag() {
    if (config.targetLag !== null) return config.targetLag;
    if (isCast) return player.hasAudio ? 1 : 0.35;
    return player.hasAudio ? 0.3 : 0.15;
  }

  function jumpLag() {
    if (config.jumpLag !== null) return config.jumpLag;
    return targetLag() + (isCast ? 3 : 0.45);
  }

  // The Chromecast's sound goes silent once playbackRate changes, and stays
  // silent after it goes back to 1.
  function canChangeRate() {
    return !(isCast && player.hasAudio);
  }

  const els = {
    video: document.getElementById('video'),
    idle: document.getElementById('idle'),
    status: document.getElementById('status'),
    overlay: document.getElementById('overlay'),
  };

  function num(value, fallback) {
    const n = parseFloat(value);
    return isFinite(n) ? n : fallback;
  }

  // ---------------------------------------------------------------- logging

  const logLines = [];

  function log(msg, toSender) {
    const line = new Date().toISOString().substr(11, 12) + ' ' + msg;
    logLines.push(line);
    if (logLines.length > 8) logLines.shift();
    console.log('[castmirror] ' + msg);
    if (toSender !== false) sendControl({ type: 'log', msg: msg });
  }

  function setStatus(text) {
    els.status.textContent = text;
  }

  // ---------------------------------------------------------------- player

  class Player {
    constructor(video) {
      this.video = video;
      this.ms = null;
      this.sb = null;
      this.queue = [];
      this.started = false;
      this.mime = '';
      this.hasAudio = false;
      this.stats = { bytes: 0, chunks: 0, jumps: 0, stalls: 0, maxQueue: 0, played: 0 };
      this.lastTime = 0;
      this.jumpTo = -Infinity;
      this.jumpedAt = 0;

      video.addEventListener('waiting', () => { if (this.started) this.stats.stalls++; });
      video.addEventListener('playing', () => els.idle.classList.add('hidden'));
      video.addEventListener('error', () => {
        const err = video.error;
        log('video error ' + (err ? err.code + ' ' + err.message : '?'));
      });
    }

    push(bytes) {
      this.stats.bytes += bytes.length;
      this.stats.chunks++;
      if (isInitSegment(bytes)) {
        this.reset(bytes);
        return;
      }
      if (!this.ms) return; // no init segment yet
      this.queue.push(bytes);
      if (this.queue.length > this.stats.maxQueue) this.stats.maxQueue = this.queue.length;
      this.pump();
    }

    // A new init segment means a new stream (the sender restarted), so start
    // over with a fresh MediaSource rather than splicing timelines.
    reset(init) {
      const mime = mimeFromInit(init);
      if (!window.MediaSource || !MediaSource.isTypeSupported(mime)) {
        log('unsupported stream type: ' + mime);
        return;
      }
      this.mime = mime;
      this.hasAudio = mime.indexOf('mp4a') >= 0;
      audioOut.reset();
      this.queue = [init];
      this.sb = null;
      this.started = false;
      this.lastTime = 0;
      this.jumpTo = -Infinity;
      const ms = new MediaSource();
      this.ms = ms;
      this.video.src = URL.createObjectURL(ms);
      ms.addEventListener('sourceopen', () => {
        if (ms !== this.ms) return;
        URL.revokeObjectURL(this.video.src);
        const sb = ms.addSourceBuffer(mime);
        sb.mode = 'segments';
        sb.addEventListener('updateend', () => this.pump());
        sb.addEventListener('error', () => log('source buffer error'));
        this.sb = sb;
        this.pump();
      });
      log('new stream ' + mime);
      setStatus('Stream starting…');
    }

    pump() {
      const sb = this.sb;
      if (!sb || sb.updating || !this.queue.length) return;
      const chunk = this.queue.shift();
      try {
        sb.appendBuffer(chunk);
      } catch (e) {
        if (e.name === 'QuotaExceededError') {
          this.queue.unshift(chunk);
          this.trim(1);
        } else {
          log('append failed: ' + e.message);
        }
      }
    }

    // Drop everything more than `keep` seconds behind the playhead.
    trim(keep) {
      const sb = this.sb;
      const v = this.video;
      if (!sb || sb.updating || !v.buffered.length) return;
      const start = v.buffered.start(0);
      if (v.currentTime - start > keep + 1) {
        try { sb.remove(start, v.currentTime - keep); } catch (e) { /* retried next tick */ }
      }
    }

    // Runs every 100 ms: start playback, then chase the live edge by speeding
    // up slightly when behind and jumping when far behind or stuck in a gap.
    tick() {
      const v = this.video;
      if (!this.sb || !v.buffered.length) return;
      const ranges = v.buffered;
      const end = ranges.end(ranges.length - 1);
      const now = Date.now();

      const target = targetLag();
      if (!this.started) {
        this.seek(Math.max(ranges.start(ranges.length - 1), end - target), now);
        this.started = true;
        const p = v.play();
        if (p && p.catch) {
          p.catch(() => { v.muted = true; v.play(); log('autoplay blocked, playing muted'); });
        }
        return;
      }

      // Media time played since the last tick: the stats use it to show
      // whether the video is really moving, since the Chromecast's frame
      // counters stay at zero.
      const step = v.currentTime - this.lastTime;
      if (step > 0 && step < 1) this.stats.played += step;
      this.lastTime = v.currentTime;

      // After a jump the decoder starts again from the previous keyframe,
      // which takes the Chromecast a moment. Jumping again before playback
      // moves would restart that and never catch up.
      const settling = v.currentTime < this.jumpTo + 0.2 && now - this.jumpedAt < 3000;
      const lag = end - v.currentTime;
      if (settling) {
        if (v.playbackRate !== 1) v.playbackRate = 1;
      } else if (audioOut.active) {
        // Separate sound sets the clock, and the picture keeps up with it by
        // playing a little faster or slower, which can't be seen.
        const want = audioOut.heardNow() + config.avOffset;
        const diff = want - v.currentTime;
        if (Math.abs(diff) > 1 || !inRanges(ranges, v.currentTime)) {
          if (inRanges(ranges, want)) {
            this.seek(want, now);
            v.playbackRate = 1;
            this.stats.jumps++;
          }
        } else {
          // Gently: the video's clock moves in steps on the Chromecast.
          v.playbackRate = 1 + Math.max(-0.1, Math.min(0.1, diff));
        }
      } else if (lag > jumpLag() || !inRanges(ranges, v.currentTime)) {
        this.seek(Math.max(0, end - target), now);
        v.playbackRate = 1;
        this.stats.jumps++;
      } else if (lag > target + 0.04 && canChangeRate()) {
        v.playbackRate = Math.min(config.maxRate, 1 + (lag - target) * 1.5);
      } else if (v.playbackRate !== 1) {
        v.playbackRate = 1;
      }
      this.trim(3);
    }

    seek(t, now) {
      this.video.currentTime = t;
      this.jumpTo = t;
      this.jumpedAt = now;
      this.lastTime = t;
    }

    lag() {
      const v = this.video;
      if (!v.buffered.length) return 0;
      return v.buffered.end(v.buffered.length - 1) - v.currentTime;
    }

    // Media time of the newest frame, or null before any.
    edge() {
      const b = this.video.buffered;
      return b.length ? b.end(b.length - 1) : null;
    }

    // Whether separate sound can play. It starts only once the video has
    // caught up after starting or a jump, so the start-up speed-up stays
    // silent. Once going it carries on through short video stalls, which
    // the video then makes up.
    canPlaySound(alreadyPlaying) {
      const v = this.video;
      if (!this.started || v.paused) return false;
      if (alreadyPlaying) return true;
      if (v.readyState < 3) return false;
      if (v.currentTime < this.jumpTo + 0.2 && Date.now() - this.jumpedAt < 3000) return false;
      return this.lag() < targetLag() + 0.3;
    }
  }

  // ---------------------------------------------------------------- sound

  const AUDIO_RATE = 48000;
  const AUDIO_HEADER = 16; // u32 size, 'cmau', u64 first sample
  // Chunks are handed to Web Audio only this far ahead, so a change in the
  // video's speed reaches the sound quickly.
  const AUDIO_HORIZON = 0.15;

  function isAudioChunk(b) {
    return b.length > AUDIO_HEADER && b[4] === 0x63 && b[5] === 0x6d && b[6] === 0x61 && b[7] === 0x75; // 'cmau'
  }

  // Plays sound sent apart from the video: 16-bit stereo PCM at 48 kHz, each
  // chunk stamped with its first sample on the stream's clock, which is the
  // video's media time. With sound inside the video the Chromecast holds
  // about 2 s and can't speed up; this way the video stays picture only.
  //
  // The sound is the clock, as in most players: chunks play back to back,
  // and the video follows (Player.tick). The Chromecast's video clock moves
  // in steps, so the sound chasing the video skipped about once a second.
  // To stay a safe distance behind the newest sound and picture, the sound
  // plays up to 1% faster or slower, 3% faster when well behind, and skips
  // ahead only when far behind or when it runs out.
  class AudioOut {
    constructor() {
      this.ctx = null;
      this.out = null;
      this.failed = false;
      this.active = false;
      this.queue = [];
      this.next = 0;      // context time the last scheduled chunk ends
      this.last = null;   // the last scheduled chunk: { when, start, speed }
      this.anchor = null; // when starting again: { media, at } to be heard at context time `at`
      this.edge = 0;      // media time where the newest sound ends
      this.trail = 0;     // how far sound arrives behind the newest frame (s)
      this.speed = 1;
      this.clock = 1;     // context seconds per real second (see trackClock)
      this.stats = { chunks: 0, played: 0, late: 0, resyncs: 0, skips: 0, waiting: 0 };
    }

    // Media time being heard now.
    heardNow() {
      const last = this.last;
      return last.start + (this.ctx.currentTime - this.latency() - last.when) * last.speed;
    }

    // Where the sound should be: a little behind the newest sound, and the
    // video's target behind the newest frame.
    safePoint() {
      const edge = player.edge();
      return Math.min(this.edge - 0.1, edge === null ? Infinity : edge - targetLag());
    }

    latency() {
      return this.ctx ? this.ctx.outputLatency || this.ctx.baseLatency || 0 : 0;
    }

    open() {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) {
        this.failed = true;
        log('no Web Audio, separate sound can\'t play');
        return false;
      }
      // The device's own sample rate: Web Audio converts the 48 kHz chunks.
      try {
        this.ctx = new Ctx({ latencyHint: params.get('latency') || 'playback' });
      } catch (e) {
        this.ctx = new Ctx();
      }
      this.clockStart = { ctx: this.ctx.currentTime, wall: performance.now() };
      this.clockMark = this.clockStart;
      this.out = this.ctx.createGain();
      this.out.connect(this.ctx.destination);
      if (this.ctx.state === 'suspended' && this.ctx.resume) this.ctx.resume();
      log('separate sound on, ' + this.ctx.sampleRate + ' Hz, ' + this.ctx.state +
        ', output latency ' + Math.round(this.latency() * 1000) + ' ms');
      return true;
    }

    reset() {
      this.active = false;
      this.next = 0;
      this.last = null;
      this.anchor = null;
    }

    // Seconds of sound played per real second since the start; should be 1.
    clockRate() {
      const wall = (performance.now() - this.clockStart.wall) / 1000;
      return wall > 1 ? (this.ctx.currentTime - this.clockStart.ctx) / wall : 1;
    }

    // The 2015 Chromecast's Web Audio clock runs about 6% slow (even for a
    // plain oscillator), so sound has to play that much faster to keep real
    // time. Measured every 2 s and smoothed.
    trackClock() {
      const wall = performance.now();
      const span = (wall - this.clockMark.wall) / 1000;
      if (span < 2) return;
      const rate = (this.ctx.currentTime - this.clockMark.ctx) / span;
      this.clockMark = { ctx: this.ctx.currentTime, wall: wall };
      if (rate > 0.8 && rate < 1.2) this.clock = this.clock * 0.8 + rate * 0.2;
    }

    push(bytes) {
      this.stats.chunks++;
      if (this.failed || (!this.ctx && !this.open())) return;
      const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      const first = view.getUint32(8) * 4294967296 + view.getUint32(12);
      const frames = (bytes.byteLength - AUDIO_HEADER) >> 2;
      if (frames <= 0) return;
      const chunk = {
        start: first / AUDIO_RATE,
        duration: frames / AUDIO_RATE,
        frames: frames,
        samples: new Int16Array(bytes.buffer, bytes.byteOffset + AUDIO_HEADER, frames * 2),
      };

      // How far sound arrives behind the picture, for the stats: rises at
      // once, falls back slowly (about 50 ms a second).
      const edge = player.edge();
      if (edge !== null) {
        this.trail = Math.max(0, edge - (chunk.start + chunk.duration), this.trail - 0.001);
      }
      this.edge = chunk.start + chunk.duration;
      this.queue.push(chunk);
      this.pump();
    }

    // Hands queued chunks to Web Audio shortly before they play. Runs on
    // every chunk and every 20 ms.
    pump() {
      if (!this.ctx) return;
      this.trackClock();
      if (!player.canPlaySound(this.active)) {
        if (this.active) log('separate sound paused for the video');
        this.reset();
        this.stats.waiting += this.queue.length;
        this.queue = [];
        return;
      }
      const now = this.ctx.currentTime;
      // Real time, in the context's slower seconds.
      const realTime = 1 / Math.max(0.9, Math.min(1.1, this.clock));
      if (this.next) {
        const safe = this.safePoint();
        const behind = safe - this.heardNow();
        if (this.next < now || behind > 0.8) {
          // Ran out of sound, or far behind live: start again from the safe point.
          if (this.next < now) this.stats.resyncs++;
          else this.stats.skips++;
          this.next = 0;
          this.anchor = { media: safe, at: now };
          this.speed = realTime;
        } else if (behind > 0.2) {
          this.speed = realTime * 1.03;
        } else {
          this.speed = realTime * (1 + Math.max(-0.01, Math.min(0.01, behind * 0.05)));
        }
      }
      if (!this.next && !this.anchor) {
        // Start in step with the video, or at the safe point if that's
        // further back (sound arriving after the picture).
        this.anchor = { media: Math.min(els.video.currentTime - config.avOffset, this.safePoint()), at: now };
        this.speed = realTime;
      }
      while (this.queue.length) {
        const chunk = this.queue[0];
        // Heard `latency` after it's scheduled, so the anchor's media time is
        // heard at the anchor's time.
        const when = this.next || this.anchor.at + (chunk.start - this.anchor.media) / this.speed - this.latency();
        if (when > now + AUDIO_HORIZON) break;
        // Up to 100 ms of back-to-back chunks go out as one buffer: the 2015
        // Chromecast can't keep up with 50 small ones a second.
        const group = [this.queue.shift()];
        let frames = chunk.frames;
        while (this.queue.length && frames + this.queue[0].frames <= AUDIO_RATE / 10 &&
               Math.abs(this.queue[0].start - (chunk.start + frames / AUDIO_RATE)) < 0.0005) {
          frames += this.queue[0].frames;
          group.push(this.queue.shift());
        }
        if (when + frames / AUDIO_RATE / this.speed < now + 0.005) {
          this.stats.late += group.length;
          continue;
        }
        if (!this.active) log('separate sound playing');
        this.active = true;
        this.play(group, frames, when, this.speed, now);
        this.last = { when: when, start: chunk.start, speed: this.speed };
        this.next = when + frames / AUDIO_RATE / this.speed;
        this.anchor = null;
      }
    }

    play(group, frames, when, speed, now) {
      const buffer = this.ctx.createBuffer(2, frames, AUDIO_RATE);
      const left = buffer.getChannelData(0);
      const right = buffer.getChannelData(1);
      let at = 0;
      for (let c = 0; c < group.length; c++) {
        const samples = group[c].samples;
        const n = group[c].frames;
        for (let i = 0; i < n; i++) {
          left[at + i] = samples[2 * i] / 32768;
          right[at + i] = samples[2 * i + 1] / 32768;
        }
        at += n;
      }
      const source = this.ctx.createBufferSource();
      source.buffer = buffer;
      if (speed !== 1) source.playbackRate.value = speed;
      source.connect(this.out);
      const start = Math.max(when, now);
      source.start(start, (start - when) * speed);
      this.stats.played += group.length;
    }

    summary() {
      if (!this.stats.chunks) return null;
      const edge = player.edge();
      const behind = this.active && edge !== null ? Math.round((edge - this.heardNow()) * 1000) + ' ms' : '-';
      return 'played ' + this.stats.played + '/' + this.stats.chunks + ', late ' + this.stats.late +
        ', waiting ' + this.stats.waiting + ', ran out ' + this.stats.resyncs + ', skips ' + this.stats.skips +
        ', speed ' + this.speed.toFixed(3) + ', behind newest frame ' + behind +
        ', arrives ' + Math.round(this.trail * 1000) + ' ms after the picture' +
        (this.ctx ? ', ' + this.ctx.state + ' at ' + this.ctx.sampleRate + ' Hz, clock ' + this.clock.toFixed(3) +
          'x (' + this.clockRate().toFixed(3) + 'x since start), out ' + Math.round(this.latency() * 1000) + ' ms' : '');
    }
  }

  function inRanges(ranges, t) {
    for (let i = 0; i < ranges.length; i++) {
      if (t >= ranges.start(i) - 0.05 && t <= ranges.end(i) + 0.05) return true;
    }
    return false;
  }

  function isInitSegment(b) {
    return b.length > 8 && b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70; // 'ftyp'
  }

  function findFourCC(b, s) {
    const c0 = s.charCodeAt(0), c1 = s.charCodeAt(1), c2 = s.charCodeAt(2), c3 = s.charCodeAt(3);
    for (let i = 0; i + 4 <= b.length; i++) {
      if (b[i] === c0 && b[i + 1] === c1 && b[i + 2] === c2 && b[i + 3] === c3) return i;
    }
    return -1;
  }

  // Build the MSE type from the init segment itself, so the codec string
  // always matches what the encoder actually produced.
  function mimeFromInit(init) {
    const codecs = [];
    const avcC = findFourCC(init, 'avcC');
    if (avcC >= 0) {
      const hex = (n) => ('0' + n.toString(16)).slice(-2);
      // avcC: configurationVersion, profile, profile compatibility, level
      codecs.push('avc1.' + hex(init[avcC + 5]) + hex(init[avcC + 6]) + hex(init[avcC + 7]));
    }
    if (findFourCC(init, 'mp4a') >= 0) codecs.push('mp4a.40.2');
    return 'video/mp4; codecs="' + codecs.join(', ') + '"';
  }

  function base64ToBytes(s) {
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  const player = new Player(els.video);
  const audioOut = new AudioOut();

  function pushMedia(bytes) {
    if (isAudioChunk(bytes)) audioOut.push(bytes);
    else player.push(bytes);
  }

  // ---------------------------------------------------------------- transports

  let castContext = null;
  let ws = null;
  let transport = 'none';
  let rtt = -1;
  let castPieces = [];
  let phoneLine = '';
  let wsUrl = '';
  let wsGeneration = 0;

  function sendControl(obj) {
    if (ws && ws.readyState === 1) {
      ws.send(JSON.stringify(obj));
    } else if (castContext) {
      try { castContext.sendCustomMessage(NS, undefined, obj); } catch (e) { /* no senders yet */ }
    }
  }

  function handleControl(msg) {
    if (!msg || !msg.type) return;
    switch (msg.type) {
      case 'hello':
        if (typeof msg.debug === 'boolean') els.overlay.hidden = !msg.debug;
        if (typeof msg.target === 'number') config.targetLag = msg.target;
        if (typeof msg.jump === 'number') config.jumpLag = msg.jump;
        log('hello from ' + (msg.name || 'sender') + ', transport ' + (msg.transport || 'auto'));
        if (msg.transport !== 'cast' && msg.ws) {
          connectWs(msg.ws, msg.transport !== 'ws');
        } else {
          useCastTransport('requested by sender');
        }
        break;
      case 'm': // one base64 piece of a media chunk; e=1 marks the last piece
        castPieces.push(msg.d);
        if (msg.e) {
          const joined = castPieces.join('');
          castPieces = [];
          pushMedia(base64ToBytes(joined));
        }
        break;
      case 'pong':
        rtt = Date.now() - msg.t;
        break;
      case 'overlay':
        els.overlay.hidden = !msg.show;
        break;
      case 'phone': // the phone's own figures, shown in the overlay
        phoneLine = String(msg.text || '');
        break;
      case 'log':
        log('sender: ' + msg.msg, false);
        break;
    }
  }

  function connectWs(url, allowFallback) {
    const gen = ++wsGeneration;
    wsUrl = url;
    if (ws) { try { ws.close(); } catch (e) { /* ignore */ } }
    let opened = false;
    let sock;
    try {
      sock = new WebSocket(url);
    } catch (e) {
      // Mixed-content blocking throws synchronously on an https page.
      log('ws blocked: ' + e.name + ' ' + e.message);
      if (allowFallback) useCastTransport('ws blocked');
      return;
    }
    ws = sock;
    sock.binaryType = 'arraybuffer';
    const timer = setTimeout(() => {
      if (!opened && gen === wsGeneration) {
        log('ws timed out');
        sock.close();
      }
    }, 3000);
    sock.onopen = () => {
      opened = true;
      clearTimeout(timer);
      transport = 'ws';
      log('ws connected ' + url);
      setStatus('Connected, waiting for video…');
    };
    sock.onmessage = (e) => {
      if (typeof e.data === 'string') {
        try { handleControl(JSON.parse(e.data)); } catch (err) { /* ignore bad json */ }
      } else {
        pushMedia(new Uint8Array(e.data));
      }
    };
    sock.onclose = () => {
      clearTimeout(timer);
      if (gen !== wsGeneration) return;
      ws = null;
      if (!opened) {
        if (allowFallback) {
          log('ws failed to connect');
          useCastTransport('ws failed');
        } else {
          setStatus('Waiting for the sender at ' + url);
          setTimeout(() => { if (gen === wsGeneration) connectWs(wsUrl, false); }, 2000);
        }
        return;
      }
      transport = 'none';
      log('ws closed, retrying');
      setStatus('Reconnecting…');
      setTimeout(() => { if (gen === wsGeneration) connectWs(wsUrl, false); }, 1000);
    };
  }

  function useCastTransport(reason) {
    wsGeneration++;
    if (ws) { try { ws.close(); } catch (e) { /* ignore */ } ws = null; }
    transport = 'cast';
    castPieces = [];
    log('using cast channel (' + reason + ')');
    setStatus('Connected, waiting for video…');
    sendControl({ type: 'ready', transport: 'cast' });
  }

  function startCast() {
    const framework = cast.framework;
    castContext = framework.CastReceiverContext.getInstance();
    castContext.addCustomMessageListener(NS, (e) => handleControl(e.data));
    castContext.addEventListener(framework.system.EventType.SENDER_DISCONNECTED, () => {
      // With a direct connection the sender isn't on the Cast channel at all.
      if (!directWs && castContext.getSenders().length === 0) {
        setStatus('Sender disconnected');
        els.idle.classList.remove('hidden');
      }
    });
    const options = new framework.CastReceiverOptions();
    options.disableIdleTimeout = true;
    options.skipPlayersLoad = true;
    options.statusText = 'CastMirror';
    options.customNamespaces = {};
    options.customNamespaces[NS] = framework.system.MessageType.JSON;
    castContext.start(options);
    log('cast receiver started', false);
  }

  // ---------------------------------------------------------------- stats

  let lastStats = { time: Date.now(), bytes: 0, frames: 0, dropped: 0, played: 0 };

  function videoQuality() {
    const v = els.video;
    if (v.getVideoPlaybackQuality) {
      const q = v.getVideoPlaybackQuality();
      return { frames: q.totalVideoFrames, dropped: q.droppedVideoFrames };
    }
    return { frames: v.webkitDecodedFrameCount || 0, dropped: v.webkitDroppedFrameCount || 0 };
  }

  function collectStats() {
    const now = Date.now();
    const q = videoQuality();
    const secs = Math.max(0.001, (now - lastStats.time) / 1000);
    const s = {
      transport: transport,
      res: els.video.videoWidth + 'x' + els.video.videoHeight,
      fps: Math.round((q.frames - lastStats.frames) / secs),
      dropped: q.dropped,
      mbps: Math.round(((player.stats.bytes - lastStats.bytes) * 8) / secs / 1e5) / 10,
      lagMs: Math.round(player.lag() * 1000),
      // Seconds of video played per second; about 1 when playing normally.
      play: Math.round(((player.stats.played - lastStats.played) / secs) * 100) / 100,
      ready: els.video.readyState,
      paused: els.video.paused,
      audio: !player.hasAudio ? 'none' : els.video.muted ? 'muted' : 'vol ' + Math.round(els.video.volume * 100),
      sound: audioOut.summary(),
      rate: Math.round(els.video.playbackRate * 100) / 100,
      queue: player.queue.length,
      maxQueue: player.stats.maxQueue,
      jumps: player.stats.jumps,
      stalls: player.stats.stalls,
      rttMs: rtt,
    };
    lastStats = { time: now, bytes: player.stats.bytes, frames: q.frames, dropped: q.dropped, played: player.stats.played };
    player.stats.maxQueue = player.queue.length;
    return s;
  }

  let statsCount = 0;
  setInterval(() => {
    const s = collectStats();
    if (!els.overlay.hidden) {
      els.overlay.textContent =
        'transport ' + s.transport + '   ' + player.mime + '\n' +
        'video     ' + s.res + ' @ ' + s.fps + ' fps   dropped ' + s.dropped + '\n' +
        'network   ' + s.mbps + ' Mbps   rtt ' + (s.rttMs < 0 ? '-' : s.rttMs + ' ms') + '\n' +
        'buffer    ' + s.lagMs + ' ms (target ' + Math.round(targetLag() * 1000) + ')   rate ' + s.rate +
          '   queue ' + s.queue + ' (max ' + s.maxQueue + ')\n' +
        'playback  ' + s.play + 'x   ready ' + s.ready + (s.paused ? '   paused' : '') +
          '   audio ' + s.audio + '\n' +
        (s.sound ? 'sound     ' + s.sound + '\n' : '') +
        (phoneLine ? 'phone     ' + phoneLine + '\n' : '') +
        'events    jumps ' + s.jumps + '   stalls ' + s.stalls + '\n\n' +
        logLines.join('\n');
    }
    if (transport !== 'none') {
      sendControl({ type: 'ping', t: Date.now() });
      if (++statsCount % 5 === 0) sendControl({ type: 'stats', stats: s });
    }
  }, 1000);

  setInterval(() => player.tick(), 100);
  setInterval(() => audioOut.pump(), 20);

  // ---------------------------------------------------------------- start

  if (directWs) {
    // debug=0 hides the stats overlay; debug=<seconds> shows it for that long.
    const debug = params.get('debug');
    els.overlay.hidden = debug === '0';
    const debugSecs = num(debug, 0);
    if (debugSecs > 0) setTimeout(() => { els.overlay.hidden = true; }, debugSecs * 1000);
    connectWs(directWs, false);
  }

  // On the Chromecast the Cast library also starts with a direct connection,
  // so the device sees a running receiver and the idle timeout stays off.
  if (isCast) {
    const script = document.createElement('script');
    script.src = CAF_URL;
    script.onload = () => {
      try {
        startCast();
      } catch (e) {
        log('cast receiver failed to start: ' + e.message);
      }
    };
    script.onerror = () => {
      if (!directWs) setStatus('Could not load the Cast receiver library');
    };
    document.head.appendChild(script);
  } else if (!directWs) {
    setStatus('Test mode: add ?ws=ws://host:port to the address');
  }
})();
