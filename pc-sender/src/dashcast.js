// DashCast is a public Cast receiver app (github.com/madmod/dashcast) that
// opens any web page on the Chromecast. Pointing it at the CastMirror receiver
// page lets the delay tests run without registering a Cast app ID.

export const DASHCAST_APP_ID = '84912283';
export const DASHCAST_NS = 'urn:x-cast:com.madmod.dashcast';

// force navigates DashCast's whole page instead of loading the address in its
// iframe: the receiver page comes over plain http from this PC, which an
// iframe inside DashCast's https page would block as mixed content.
export function dashcastLoadMessage(url) {
  return { url, force: true, reload: false, reload_time: 0 };
}

// The receiver page address, carrying the settings that the hello message
// would otherwise send over the Cast channel. target and jump are seconds;
// avOffset is milliseconds.
export function receiverPageUrl(base, { ws, debug, target, jump, avOffset }) {
  const url = new URL(base);
  url.searchParams.set('ws', ws);
  if (!debug) url.searchParams.set('debug', '0');
  if (target !== undefined) url.searchParams.set('target', String(target));
  if (jump !== undefined) url.searchParams.set('jump', String(jump));
  if (avOffset !== undefined) url.searchParams.set('avoffset', String(avOffset));
  return url.toString();
}
