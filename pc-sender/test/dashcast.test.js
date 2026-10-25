import { test } from 'node:test';
import assert from 'node:assert/strict';

import { dashcastLoadMessage, receiverPageUrl } from '../src/dashcast.js';

test('receiver page address carries the WebSocket and settings', () => {
  const url = new URL(receiverPageUrl('http://192.168.1.5:8080/receiver/', {
    ws: 'ws://192.168.1.5:8765',
    debug: false,
    target: 0.3,
    jump: 0.75,
  }));
  assert.equal(url.origin + url.pathname, 'http://192.168.1.5:8080/receiver/');
  assert.equal(url.searchParams.get('ws'), 'ws://192.168.1.5:8765');
  assert.equal(url.searchParams.get('debug'), '0');
  assert.equal(url.searchParams.get('target'), '0.3');
  assert.equal(url.searchParams.get('jump'), '0.75');
});

test('receiver page address leaves out unset settings', () => {
  const url = new URL(receiverPageUrl('https://example.github.io/castmirror/receiver/', {
    ws: 'ws://10.0.0.2:8765',
    debug: true,
  }));
  assert.deepEqual([...url.searchParams.keys()], ['ws']);
});

test('DashCast loads the page in place of its own', () => {
  assert.deepEqual(dashcastLoadMessage('http://x/'), { url: 'http://x/', force: true, reload: false, reload_time: 0 });
});
