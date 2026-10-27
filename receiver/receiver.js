// CastMirror receiver: plays a live fragmented-MP4 stream with Media Source
// Extensions and keeps playback pinned to the newest frame.
//
// Media arrives as complete MP4 chunks: one init segment (ftyp+moov), then one
// moof+mdat fragment per frame. Two transports carry them:
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

  // ---------------------------------------------------------------- transports

  let castContext = null;
  let ws = null;
  let transport = 'none';
  let rtt = -1;
  let castPieces = [];
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
          player.push(base64ToBytes(joined));
        }
        break;
      case 'pong':
        rtt = Date.now() - msg.t;
        break;
      case 'overlay':
        els.overlay.hidden = !msg.show;
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
        player.push(new Uint8Array(e.data));
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
        'events    jumps ' + s.jumps + '   stalls ' + s.stalls + '\n\n' +
        logLines.join('\n');
    }
    if (transport !== 'none') {
      sendControl({ type: 'ping', t: Date.now() });
      if (++statsCount % 5 === 0) sendControl({ type: 'stats', stats: s });
    }
  }, 1000);

  setInterval(() => player.tick(), 100);

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
