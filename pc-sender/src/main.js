#!/usr/bin/env node
// CastMirror PC test sender (Phase 1).
//
// Streams this PC's desktop (or a test pattern, or a video file) to the
// CastMirror receiver on a Chromecast, using the same chunk format and
// transports the iPhone app will use, so the delay can be measured before
// any iOS work.

import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { WebSocketServer } from 'ws';

import { CastClient } from './castv2.js';
import { DASHCAST_APP_ID, DASHCAST_NS, dashcastLoadMessage, receiverPageUrl } from './dashcast.js';
import { discoverChromecasts, localAddressFor } from './discovery.js';
import { startFfmpeg } from './ffmpeg.js';
import { FragmentSplitter } from './mp4.js';
import { PcmPacker } from './pcm.js';
import { startReplay } from './replay.js';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const CONFIG = JSON.parse(fs.readFileSync(path.join(ROOT, 'castmirror.config.json'), 'utf8'));
const NS = CONFIG.namespace;
const CAST_PIECE = 48000; // base64 chars per Cast message (the limit is 64 KB)

const HELP = `
CastMirror PC test sender

  npm run list                     find Chromecasts on the network
  npm start                        stream the desktop to the Chromecast
  npm run local                    test in a browser on this PC, no Chromecast

Options:
  --host <ip>           Chromecast address (skips discovery)
  --name <text>         pick the Chromecast whose name contains <text>
  --app <id>            Cast app ID (default: castAppId in castmirror.config.json)
  --receiver <r>        custom | dashcast    (default custom, or dashcast with no app ID)
                        dashcast opens the receiver page through the public
                        DashCast app, served from this PC, so no app ID is needed
  --page <url>          receiver page for dashcast      (default served from this PC)
  --source <s>          desktop | test | synctest | file | replay  (default desktop)
                        synctest flashes white with a beep at the start of every second
  --file <path>         video file for --source file (loops), or a stream
                        recorded by the iOS tests for --source replay
  --capture <c>         ddagrab | gdigrab               (default ddagrab)
  --monitor <n>         monitor index for ddagrab       (default 0)
  --size <WxH>          output size                     (default 1920x1080)
  --fps <n>             frame rate                      (default 30)
  --bitrate <rate>      video bitrate, e.g. 6M 8M 10M   (default 8M)
  --gop <frames>        frames between keyframes        (default 60)
  --encoder <e>         x264 | qsv                      (default x264)
  --preset <p>          x264 preset                     (default ultrafast)
  --audio               add a test tone (file sources keep their own audio)
  --sound <s>           mp4 | pcm  where the sound goes (default mp4)
                        mp4: inside the video stream (the Chromecast holds ~2 s)
                        pcm: apart from it, played by the receiver with Web Audio
  --avoffset <ms>       play separate sound this much later (+) or earlier (-)
  --transport <t>       auto | ws | cast                (default auto)
  --port <n>            WebSocket port                  (default 8765)
  --target <ms>         receiver buffer target
                        (default 350 on a Chromecast, 1000 with audio, where it can't
                        speed up to catch up; 150, or 300 with audio, in a browser)
  --jump <ms>           receiver jumps to live past this
                        (default target + 3000 on a Chromecast, target + 450 in a browser)
  --quiet               hide the overlay on the TV
  --local               browser test mode (http://localhost:8080)
`;

function parseOptions() {
  const { values } = parseArgs({
    options: {
      host: { type: 'string' },
      name: { type: 'string' },
      app: { type: 'string' },
      receiver: { type: 'string' },
      page: { type: 'string' },
      source:{ type: 'string', default: 'desktop' },
      file: { type: 'string' },
      capture: { type: 'string', default: 'ddagrab' },
      monitor: { type: 'string', default: '0' },
      size: { type: 'string', default: '1920x1080' },
      fps: { type: 'string', default: '30' },
      bitrate: { type: 'string', default: '8M' },
      gop: { type: 'string', default: '60' },
      encoder: { type: 'string', default: 'x264' },
      preset: { type: 'string', default: 'ultrafast' },
      audio: { type: 'boolean', default: false },
      sound: { type: 'string', default: 'mp4' },
      avoffset: { type: 'string' },
      transport: { type: 'string', default: 'auto' },
      port: { type: 'string', default: '8765' },
      'http-port': { type: 'string', default: '8080' },
      target: { type: 'string' },
      jump: { type: 'string' },
      quiet: { type: 'boolean', default: false },
      local: { type: 'boolean', default: false },
      list: { type: 'boolean', default: false },
      help: { type: 'boolean', short: 'h', default: false },
    },
  });
  const [width, height] = values.size.split('x').map(Number);
  return {
    ...values,
    width,
    height,
    fps: Number(values.fps),
    gop: Number(values.gop),
    port: Number(values.port),
    httpPort: Number(values['http-port']),
    target: values.target === undefined ? undefined : Number(values.target) / 1000,
    jump: values.jump === undefined ? undefined : Number(values.jump) / 1000,
    avOffset: values.avoffset === undefined ? undefined : Number(values.avoffset),
  };
}

// ------------------------------------------------------------------ streaming

// One FFmpeg run feeding one receiver connection. Never queues frames: when
// the connection backs up it drops frames until the next keyframe.
class Stream {
  constructor(opts, sink) {
    this.opts = opts;
    this.sink = sink;
    this.splitter = new FragmentSplitter();
    this.waitingForKey = true;
    this.stopped = false;
    this.backlogLimit = Math.max(256 * 1024, bitrateBytesPerSec(opts.bitrate) * 0.2);
    this.stats = { frames: 0, bytes: 0, soundBytes: 0, dropped: 0, since: Date.now() };
    this.statsTimer = setInterval(() => this.printStats(), 5000);
  }

  start() {
    console.log(`[stream] starting ${this.opts.source} ${this.opts.width}x${this.opts.height}@${this.opts.fps} `
      + `${this.opts.bitrate} via ${this.sink.kind}${this.opts.sound === 'pcm' ? ', separate sound' : ''}`);
    this.splitter = new FragmentSplitter();
    if (this.opts.sound === 'pcm' && this.opts.source !== 'replay') {
      this.listenForSound((pcmUrl) => this.run({ ...this.opts, pcmUrl }));
    } else {
      this.run(this.opts);
    }
  }

  // FFmpeg writes separate sound to a local TCP port (Windows can't reliably
  // give it a third pipe), and it goes out as 'cmau' chunks.
  listenForSound(then) {
    if (this.soundServer) this.soundServer.close();
    const packer = new PcmPacker();
    const server = net.createServer((sock) => {
      sock.on('data', (d) => {
        for (const chunk of packer.push(d)) this.sendSound(chunk);
      });
      sock.on('error', () => { /* FFmpeg restarting */ });
    });
    server.listen(0, '127.0.0.1', () => then(`tcp://127.0.0.1:${server.address().port}`));
    this.soundServer = server;
  }

  sendSound(chunk) {
    if (this.stopped) return;
    this.sink.send(chunk);
    this.stats.soundBytes += chunk.length;
  }

  run(runOpts) {
    const startedAt = Date.now();
    const run = runOpts.source === 'replay' ? startReplay : startFfmpeg;
    this.proc = run(runOpts, (d) => this.onData(d), (code) => {
      if (this.stopped) return;
      // Desktop capture ends whenever Windows takes the screen away (lock
      // screen, UAC prompt, display change), so start again. The new init
      // segment makes the receiver start a fresh stream.
      if (Date.now() - startedAt < 3000) {
        console.log(`[stream] ffmpeg exited (code ${code}) right after starting, giving up`);
        return;
      }
      console.log(`[stream] ffmpeg exited (code ${code}), restarting`);
      this.restartTimer = setTimeout(() => this.start(), 1000);
    });
  }

  onData(d) {
    let chunks;
    try {
      chunks = this.splitter.push(d);
    } catch (e) {
      console.log('[stream] ' + e.message);
      this.stop();
      return;
    }
    for (const c of chunks) {
      if (c.kind === 'audio') {
        this.sendSound(c.data);
        continue;
      }
      if (c.kind === 'init') {
        this.sink.send(c.data);
        this.waitingForKey = true;
        continue;
      }
      if (this.waitingForKey && !c.keyframe) {
        this.stats.dropped++;
        continue;
      }
      if (this.sink.backlog() > this.backlogLimit) {
        this.waitingForKey = true;
        this.stats.dropped++;
        continue;
      }
      this.waitingForKey = false;
      this.sink.send(c.data);
      if (c.hasVideo) this.stats.frames++;
      this.stats.bytes += c.data.length;
    }
  }

  printStats() {
    const secs = (Date.now() - this.stats.since) / 1000;
    const fps = (this.stats.frames / secs).toFixed(1);
    const mbps = ((this.stats.bytes * 8) / secs / 1e6).toFixed(1);
    const sound = this.stats.soundBytes ? `, sound ${Math.round(this.stats.soundBytes / secs / 1024)} KB/s` : '';
    console.log(`[stream] sent ${fps} fps, ${mbps} Mbps${sound}, dropped ${this.stats.dropped}, `
      + `backlog ${Math.round(this.sink.backlog() / 1024)} KB`);
    this.stats = { frames: 0, bytes: 0, soundBytes: 0, dropped: 0, since: Date.now() };
  }

  stop() {
    if (this.stopped) return;
    this.stopped = true;
    clearInterval(this.statsTimer);
    clearTimeout(this.restartTimer);
    if (this.proc) this.proc.kill();
    if (this.soundServer) this.soundServer.close();
  }
}

function bitrateBytesPerSec(bitrate) {
  const m = /^(\d+(?:\.\d+)?)([kKmM]?)$/.exec(bitrate);
  if (!m) return 1e6;
  const scale = { k: 1e3, K: 1e3, m: 1e6, M: 1e6, '': 1 }[m[2]];
  return (parseFloat(m[1]) * scale) / 8;
}

function wsSink(sock) {
  return {
    kind: 'ws',
    send: (data) => sock.send(data, { binary: true }),
    backlog: () => sock.bufferedAmount,
  };
}

function castSink(client) {
  return {
    kind: 'cast',
    send: (data) => {
      const b64 = data.toString('base64');
      for (let i = 0; i < b64.length; i += CAST_PIECE) {
        const last = i + CAST_PIECE >= b64.length;
        client.sendToApp(NS, { type: 'm', d: b64.slice(i, i + CAST_PIECE), e: last ? 1 : 0 });
      }
    },
    backlog: () => client.backlog,
  };
}

// Messages from the receiver arrive the same way over either transport.
function handleReceiverMessage(msg, reply, onReady) {
  if (!msg || !msg.type) return;
  if (msg.type === 'ping') {
    reply({ type: 'pong', t: msg.t });
  } else if (msg.type === 'log') {
    console.log('[tv] ' + msg.msg);
  } else if (msg.type === 'stats') {
    const s = msg.stats;
    console.log(`[tv] ${s.res} @ ${s.fps} fps via ${s.transport}, plays ${s.play}x (ready ${s.ready}`
      + `${s.paused ? ', paused' : ''}), audio ${s.audio}, `
      + `buffer ${s.lagMs} ms, rtt ${s.rttMs} ms, rate ${s.rate}, `
      + `${s.mbps} Mbps, dropped ${s.dropped}, jumps ${s.jumps}, stalls ${s.stalls}, queue max ${s.maxQueue}`
      + (s.sound ? `\n[tv]   sound ${s.sound}` : ''));
  } else if (msg.type === 'ready' && onReady) {
    onReady(msg);
  }
}

let current = null;

function replaceStream(stream) {
  if (current) current.stop();
  current = stream;
  if (stream) stream.start();
}

function startWebSocketServer(opts, host) {
  const wss = new WebSocketServer({ host, port: opts.port, perMessageDeflate: false });
  wss.on('connection', (sock, req) => {
    console.log('[ws] receiver connected from ' + req.socket.remoteAddress);
    req.socket.setNoDelay(true);
    const stream = new Stream(opts, wsSink(sock));
    replaceStream(stream);
    sock.on('message', (data, isBinary) => {
      if (isBinary) return;
      let msg;
      try { msg = JSON.parse(data.toString()); } catch (e) { return; }
      handleReceiverMessage(msg, (obj) => sock.send(JSON.stringify(obj)));
    });
    sock.on('close', () => {
      console.log('[ws] receiver disconnected');
      if (current === stream) replaceStream(null);
    });
  });
  wss.on('error', (e) => {
    console.error('[ws] ' + e.message);
    process.exit(1);
  });
  return wss;
}

// ------------------------------------------------------------------ modes

async function runList() {
  console.log('Looking for Chromecasts…');
  const devices = await discoverChromecasts();
  if (!devices.length) {
    console.log('None found. Check the PC is on the same Wi-Fi network as the Chromecast.');
    return;
  }
  for (const d of devices) console.log(`  ${d.name}  ${d.host}  ${d.model}`);
}

// Serves the receiver page and the stopwatch from this checkout.
function startHttpServer(opts, host) {
  const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };
  const server = http.createServer((req, res) => {
    const urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    let file = urlPath === '/stopwatch.html'
      ? path.join(ROOT, 'tools', 'stopwatch.html')
      : path.join(ROOT, urlPath.endsWith('/') ? urlPath + 'index.html' : urlPath);
    if (!file.startsWith(path.join(ROOT, 'receiver')) && !file.startsWith(path.join(ROOT, 'tools'))) {
      file = '';
    }
    fs.readFile(file, (err, body) => {
      if (err) {
        res.writeHead(404);
        res.end('not found');
        return;
      }
      res.writeHead(200, {
        'content-type': types[path.extname(file)] || 'application/octet-stream',
        // Receiver edits take effect on the next cast.
        'cache-control': 'no-store',
      });
      res.end(body);
    });
  });
  server.on('error', (e) => {
    console.error('[http] ' + e.message);
    process.exit(1);
  });
  server.listen(opts.httpPort, host);
  return server;
}

function runLocal(opts) {
  startHttpServer(opts, '127.0.0.1');
  startWebSocketServer(opts, '127.0.0.1');
  console.log(`Open http://localhost:${opts.httpPort}/receiver/?ws=ws://localhost:${opts.port}`);
  console.log(`Stopwatch for delay tests: http://localhost:${opts.httpPort}/stopwatch.html`);
}

async function runCast(opts) {
  const mode = opts.receiver || (opts.app || CONFIG.castAppId ? 'custom' : 'dashcast');
  if (mode !== 'custom' && mode !== 'dashcast') {
    console.error('--receiver must be custom or dashcast.');
    process.exit(1);
  }
  const dashcast = mode === 'dashcast';
  const appId = dashcast ? DASHCAST_APP_ID : opts.app || CONFIG.castAppId;
  if (!appId) {
    console.error('No Cast app ID yet. Register the receiver in the Google Cast SDK Developer Console,\n'
      + 'then put the ID in castmirror.config.json (castAppId) or pass --app <id>.\n'
      + 'Or use --receiver dashcast, which needs no app ID.');
    process.exit(1);
  }
  if (dashcast && opts.transport === 'cast') {
    console.error('DashCast mode only works over the direct WebSocket (--transport ws).');
    process.exit(1);
  }

  let device;
  if (opts.host) {
    device = { name: opts.host, host: opts.host, port: 8009 };
  } else {
    console.log('Looking for Chromecasts…');
    const devices = (await discoverChromecasts())
      .filter((d) => !opts.name || d.name.toLowerCase().includes(opts.name.toLowerCase()));
    if (!devices.length) {
      console.error('No Chromecast found. Try --host <ip> (the Google Home app shows it).');
      process.exit(1);
    }
    device = devices[0];
  }
  const lanIp = localAddressFor(device.host);

  if (opts.transport !== 'cast') startWebSocketServer(opts, '0.0.0.0');
  if (dashcast) startHttpServer(opts, '0.0.0.0');

  const client = new CastClient();
  console.log(`Connecting to ${device.name} (${device.host})…`);
  await client.connect(device.host, device.port);
  // DashCast restarts so it is on its own page, ready to take an address.
  await client.launch(appId, dashcast ? { namespace: DASHCAST_NS, restart: true } : { namespace: NS });
  console.log(dashcast ? 'DashCast running.' : 'Receiver app running.');

  client.on('message', (namespace, data) => {
    if (namespace !== NS) return;
    handleReceiverMessage(data, (obj) => client.sendToApp(NS, obj), () => {
      replaceStream(new Stream(opts, castSink(client)));
    });
  });
  let stopping = false;
  const shutdown = async () => {
    stopping = true;
    replaceStream(null);
    await client.stopApp();
    client.close();
    process.exit(0);
  };
  const appGone = () => {
    if (stopping) return;
    console.log('The receiver app was closed on the Chromecast.');
    replaceStream(null);
    process.exit(0);
  };
  client.on('app-stopped', appGone);
  // DashCast drops its Cast connection when it hands the TV over to the
  // receiver page, which keeps running.
  if (!dashcast) client.on('app-closed', appGone);
  client.on('close', () => {
    if (stopping) return;
    console.log('Lost the connection to the Chromecast.');
    replaceStream(null);
    process.exit(1);
  });
  process.on('SIGINT', shutdown);

  if (dashcast) {
    const page = receiverPageUrl(opts.page || `http://${lanIp}:${opts.httpPort}/receiver/`, {
      ws: `ws://${lanIp}:${opts.port}`,
      debug: !opts.quiet,
      target: opts.target,
      jump: opts.jump,
      avOffset: opts.avOffset,
    });
    client.sendToApp(DASHCAST_NS, dashcastLoadMessage(page));
    console.log(`Opening ${page} on the TV. Ctrl+C stops.`);
    return;
  }

  client.sendToApp(NS, {
    type: 'hello',
    name: os.hostname(),
    transport: opts.transport,
    ws: opts.transport === 'cast' ? undefined : `ws://${lanIp}:${opts.port}`,
    debug: !opts.quiet,
    target: opts.target,
    jump: opts.jump,
  });
  console.log(`Sent hello (ws://${lanIp}:${opts.port}, transport ${opts.transport}). Ctrl+C stops.`);
}

const opts = parseOptions();
if (opts.help) {
  console.log(HELP);
} else if (opts.list) {
  await runList();
} else if (opts.local) {
  runLocal(opts);
} else {
  await runCast(opts);
}
