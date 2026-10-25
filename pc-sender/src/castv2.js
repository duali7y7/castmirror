// Minimal Cast v2 sender: TLS to port 8009, length-prefixed CastMessage
// protobufs, JSON payloads. Just enough to launch a receiver app and exchange
// messages with it. The iOS CastClient follows the same steps.

import tls from 'node:tls';
import { EventEmitter } from 'node:events';

export const NS_CONNECTION = 'urn:x-cast:com.google.cast.tp.connection';
export const NS_HEARTBEAT = 'urn:x-cast:com.google.cast.tp.heartbeat';
export const NS_RECEIVER = 'urn:x-cast:com.google.cast.receiver';

// CastMessage (cast_channel.proto), encoded by hand:
//   1 protocol_version  varint, 0 = CASTV2_1_0
//   2 source_id         string
//   3 destination_id    string
//   4 namespace         string
//   5 payload_type      varint, 0 = STRING, 1 = BINARY
//   6 payload_utf8      string
//   7 payload_binary    bytes
export function encodeCastMessage({ source, destination, namespace, data }) {
  const parts = [];
  const varint = (n) => {
    const bytes = [];
    while (n > 0x7f) {
      bytes.push((n & 0x7f) | 0x80);
      n = Math.floor(n / 128);
    }
    bytes.push(n);
    parts.push(Buffer.from(bytes));
  };
  const key = (field, wireType) => varint((field << 3) | wireType);
  const string = (field, s) => {
    const b = Buffer.from(s, 'utf8');
    key(field, 2);
    varint(b.length);
    parts.push(b);
  };

  key(1, 0); varint(0);
  string(2, source);
  string(3, destination);
  string(4, namespace);
  key(5, 0); varint(0);
  string(6, data);

  const body = Buffer.concat(parts);
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length);
  return Buffer.concat([header, body]);
}

export function decodeCastMessage(buf) {
  const msg = {};
  let pos = 0;
  const varint = () => {
    let result = 0;
    let scale = 1;
    let b;
    do {
      b = buf[pos++];
      result += (b & 0x7f) * scale;
      scale *= 128;
    } while (b & 0x80);
    return result;
  };
  while (pos < buf.length) {
    const k = varint();
    const field = k >>> 3;
    const wireType = k & 7;
    if (wireType === 0) {
      const v = varint();
      if (field === 1) msg.protocolVersion = v;
      else if (field === 5) msg.payloadType = v;
    } else if (wireType === 2) {
      const len = varint();
      const value = buf.subarray(pos, pos + len);
      pos += len;
      if (field === 2) msg.source = value.toString('utf8');
      else if (field === 3) msg.destination = value.toString('utf8');
      else if (field === 4) msg.namespace = value.toString('utf8');
      else if (field === 6) msg.data = value.toString('utf8');
      else if (field === 7) msg.binary = value;
    } else {
      throw new Error('unexpected protobuf wire type ' + wireType);
    }
  }
  return msg;
}

export class CastClient extends EventEmitter {
  constructor() {
    super();
    this.source = 'sender-castmirror';
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.nextRequestId = 1;
    this.pending = new Map();
    this.heartbeat = null;
    this.transportId = null;
    this.sessionId = null;
  }

  connect(host, port = 8009) {
    return new Promise((resolve, reject) => {
      // Chromecasts present a Google device certificate rather than a public
      // CA chain. This sender doesn't need to authenticate the device, so it
      // skips verification, as other third-party senders do.
      const socket = tls.connect({ host, port, rejectUnauthorized: false }, () => {
        socket.setNoDelay(true);
        this.send('receiver-0', NS_CONNECTION, { type: 'CONNECT' });
        this.heartbeat = setInterval(() => this.send('receiver-0', NS_HEARTBEAT, { type: 'PING' }), 5000);
        resolve();
      });
      socket.on('data', (d) => this.onData(d));
      socket.once('error', reject);
      socket.on('error', (e) => this.emit('error', e));
      socket.on('close', () => {
        clearInterval(this.heartbeat);
        for (const { reject: fail } of this.pending.values()) fail(new Error('connection closed'));
        this.pending.clear();
        this.emit('close');
      });
      this.socket = socket;
    });
  }

  send(destination, namespace, obj) {
    if (!this.socket || this.socket.destroyed) return false;
    return this.socket.write(encodeCastMessage({
      source: this.source,
      destination,
      namespace,
      data: JSON.stringify(obj),
    }));
  }

  request(destination, namespace, obj, timeoutMs = 15000) {
    const requestId = this.nextRequestId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new Error(obj.type + ' timed out'));
      }, timeoutMs);
      this.pending.set(requestId, {
        resolve: (v) => { clearTimeout(timer); resolve(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
      this.send(destination, namespace, Object.assign({}, obj, { requestId }));
    });
  }

  onData(d) {
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, d]) : d;
    while (this.buffer.length >= 4) {
      const len = this.buffer.readUInt32BE(0);
      if (this.buffer.length < 4 + len) break;
      const msg = decodeCastMessage(this.buffer.subarray(4, 4 + len));
      this.buffer = this.buffer.subarray(4 + len);
      this.onMessage(msg);
    }
  }

  onMessage(msg) {
    if (msg.data === undefined) return;
    let data;
    try {
      data = JSON.parse(msg.data);
    } catch (e) {
      return;
    }
    if (msg.namespace === NS_HEARTBEAT && data.type === 'PING') {
      this.send(msg.source, NS_HEARTBEAT, { type: 'PONG' });
      return;
    }
    if (data.requestId && this.pending.has(data.requestId)) {
      const { resolve } = this.pending.get(data.requestId);
      this.pending.delete(data.requestId);
      resolve(data);
    }
    if (msg.namespace === NS_CONNECTION && data.type === 'CLOSE' && msg.source === this.transportId) {
      this.emit('app-closed');
    }
    this.emit('message', msg.namespace, data, msg.source);
  }

  // Launches the receiver app (or joins it if already running) and opens a
  // virtual connection to it.
  async launch(appId) {
    let reply = await this.request('receiver-0', NS_RECEIVER, { type: 'LAUNCH', appId });
    if (reply.type === 'LAUNCH_ERROR') throw new Error('launch failed: ' + (reply.reason || 'unknown'));
    let app = findApp(reply, appId);
    for (let i = 0; !app && i < 20; i++) {
      await new Promise((r) => setTimeout(r, 500));
      reply = await this.request('receiver-0', NS_RECEIVER, { type: 'GET_STATUS' });
      app = findApp(reply, appId);
    }
    if (!app) throw new Error('the Chromecast did not start app ' + appId);
    this.transportId = app.transportId;
    this.sessionId = app.sessionId;
    this.send(this.transportId, NS_CONNECTION, { type: 'CONNECT' });
    return app;
  }

  sendToApp(namespace, obj) {
    return this.send(this.transportId, namespace, obj);
  }

  async stopApp() {
    if (!this.sessionId) return;
    try {
      await this.request('receiver-0', NS_RECEIVER, { type: 'STOP', sessionId: this.sessionId }, 3000);
    } catch (e) {
      // Already gone.
    }
  }

  // Bytes queued in the socket but not yet sent.
  get backlog() {
    return this.socket ? this.socket.writableLength : 0;
  }

  close() {
    clearInterval(this.heartbeat);
    if (this.socket) this.socket.end();
  }
}

function findApp(reply, appId) {
  const apps = (reply && reply.status && reply.status.applications) || [];
  return apps.find((a) => a.appId === appId);
}
