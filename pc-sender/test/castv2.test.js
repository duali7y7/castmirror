import { test } from 'node:test';
import assert from 'node:assert/strict';

import { decodeCastMessage, encodeCastMessage } from '../src/castv2.js';

test('CastMessage round-trips through the protobuf encoding', () => {
  const data = JSON.stringify({ type: 'm', d: 'x'.repeat(50000), e: 1 });
  const framed = encodeCastMessage({
    source: 'sender-castmirror',
    destination: 'web-5',
    namespace: 'urn:x-cast:com.castmirror.v1',
    data,
  });
  assert.equal(framed.readUInt32BE(0), framed.length - 4);

  const msg = decodeCastMessage(framed.subarray(4));
  assert.equal(msg.protocolVersion, 0);
  assert.equal(msg.payloadType, 0);
  assert.equal(msg.source, 'sender-castmirror');
  assert.equal(msg.destination, 'web-5');
  assert.equal(msg.namespace, 'urn:x-cast:com.castmirror.v1');
  assert.equal(msg.data, data);
});

test('encodes a CONNECT message byte-for-byte like the reference protobuf', () => {
  const framed = encodeCastMessage({
    source: 'a', destination: 'b', namespace: 'c', data: '{}',
  });
  // 08 00 | 12 01 'a' | 1a 01 'b' | 22 01 'c' | 28 00 | 32 02 '{}'
  const expected = Buffer.from('08001201611a0162220163280032027b7d', 'hex');
  assert.deepEqual(framed.subarray(4), expected);
});
