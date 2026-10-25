// Finds Chromecasts on the local network (mDNS service _googlecast._tcp).

import os from 'node:os';
import { Bonjour } from 'bonjour-service';

// Queries go out on every IPv4 adapter separately: with several adapters
// (VPNs such as Tailscale), the default multicast route often isn't the Wi-Fi.
export function discoverChromecasts(timeoutMs = 4000) {
  return new Promise((resolve) => {
    const found = new Map();
    const instances = localIPv4Addresses().map((a) => new Bonjour({ interface: a.address }));
    const browsers = instances.map((bonjour) => bonjour.find({ type: 'googlecast' }, (svc) => {
      const txt = svc.txt || {};
      const host = (svc.addresses || []).find((a) => a.includes('.'))
        || (svc.referer && svc.referer.address);
      if (!host) return;
      found.set(txt.id || svc.name, {
        name: txt.fn || svc.name,
        model: txt.md || '',
        host,
        port: svc.port || 8009,
      });
    }));
    setTimeout(() => {
      browsers.forEach((b) => b.stop());
      instances.forEach((b) => b.destroy());
      resolve([...found.values()]);
    }, timeoutMs);
  });
}

function localIPv4Addresses() {
  const result = [];
  for (const addrs of Object.values(os.networkInterfaces())) {
    for (const a of addrs || []) {
      if (a.family === 'IPv4' && !a.internal) result.push(a);
    }
  }
  return result;
}

// Picks this PC's IPv4 address on the same subnet as the Chromecast, so the
// receiver can reach the WebSocket server.
export function localAddressFor(remoteHost) {
  const candidates = localIPv4Addresses();
  const toInt = (ip) => ip.split('.').reduce((n, part) => n * 256 + Number(part), 0);
  if (remoteHost && /^\d+\.\d+\.\d+\.\d+$/.test(remoteHost)) {
    const remote = toInt(remoteHost);
    for (const a of candidates) {
      const mask = toInt(a.netmask);
      if (((toInt(a.address) ^ remote) & mask) === 0) return a.address;
    }
  }
  return candidates.length ? candidates[0].address : '127.0.0.1';
}
