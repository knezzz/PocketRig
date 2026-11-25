// Native push for the PocketRig watcher: APNs (HTTP/2, ES256 JWT) and FCM HTTP v1
// (service-account JWT -> OAuth token). Node built-ins only. The payload shape is
// host/watcher/PUSH.md. Keys live in ~/.config/pocketrig (mode 600), never in messages.
import { createPrivateKey, createSign, randomBytes, sign } from 'node:crypto';
import fs from 'node:fs';
import http2 from 'node:http2';
import path from 'node:path';

const b64 = (v) => Buffer.from(typeof v === 'string' ? v : JSON.stringify(v)).toString('base64url');

/** What a ntfy-shaped message becomes on a device: category, answer buttons, link. */
export function toPush(msg) {
  const http = (msg.actions || []).filter((a) => a.action === 'http');
  const actions = http.map((a) => {
    let body = {};
    try { body = JSON.parse(a.body); } catch { /* none */ }
    return { id: body.snooze ? 'snooze' : body.answer, label: a.label, url: a.url, body: a.body };
  }).filter((a) => a.id);
  const labels = (msg.actions || []).map((a) => a.label);
  const category = actions.some((a) => a.id === 'allow') ? 'pr-permission'
    : actions.some((a) => a.id === 'snooze') ? 'pr-blocked'
    : labels.includes('Reply…') ? 'pr-question'
    : msg.priority >= 4 ? 'pr-blocked' : 'pr-result';
  return {
    // APNs refuses payloads over 4 KB: keep the text well under it.
    title: (msg.title || '').slice(0, 200), body: (msg.message || '').slice(0, 1000), category, seq: msg.sequence_id || '',
    link: msg.click || (msg.actions || []).find((a) => a.action === 'view')?.url || '',
    actions, ask: (msg.priority || 3) >= 4,
  };
}

const jwtCache = new Map();
/** The APNs JWT for this key, reused ~30 min (Apple wants a new one every 20-60 min). */
function cachedJwt(pem, keyId, teamId, now = Date.now()) {
  const k = `${keyId}/${teamId}`, c = jwtCache.get(k);
  if (c && now - c.at < 30 * 60000) return c.value;
  const value = apnsJwt(pem, keyId, teamId, now);
  jwtCache.set(k, { value, at: now });
  return value;
}

export function apnsJwt(keyPem, keyId, teamId, now = Date.now()) {
  const head = `${b64({ alg: 'ES256', kid: keyId })}.${b64({ iss: teamId, iat: Math.floor(now / 1000) })}`;
  return `${head}.${sign('sha256', Buffer.from(head), { key: keyPem, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}

/** The APNs request for one device: headers and JSON body. */
export function apnsRequest(apns, device, p, jwt) {
  const aps = { alert: { title: p.title, body: p.body }, category: p.category, 'thread-id': p.seq || undefined,
    'interruption-level': p.ask ? 'time-sensitive' : 'passive' };
  return {
    host: device.env === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com',
    path: `/3/device/${device.token}`,
    headers: {
      authorization: `bearer ${jwt}`, 'apns-topic': apns.bundleId, 'apns-push-type': 'alert', 'apns-priority': '10',
      ...(p.seq ? { 'apns-collapse-id': p.seq.slice(0, 64) } : {}),
    },
    body: JSON.stringify({ aps, link: p.link, seq: p.seq, actions: JSON.stringify(p.actions) }),
  };
}

/** The FCM v1 message: data only, so the app builds the notification and its buttons. */
export function fcmMessage(device, p) {
  return {
    message: {
      token: device.token,
      data: { title: p.title, body: p.body, category: p.category, seq: p.seq, link: p.link, actions: JSON.stringify(p.actions) },
      android: { priority: 'HIGH', ...(p.seq ? { collapse_key: p.seq } : {}) },
    },
  };
}

/** A service-account JWT, exchanged for a short-lived OAuth access token. */
export async function fcmAccessToken(sa, { fetchImpl = fetch, now = Date.now() } = {}) {
  const iat = Math.floor(now / 1000);
  const head = `${b64({ alg: 'RS256', typ: 'JWT' })}.${b64({ iss: sa.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging', aud: sa.token_uri || 'https://oauth2.googleapis.com/token', iat, exp: iat + 3600 })}`;
  const sig = createSign('RSA-SHA256').update(head).sign(createPrivateKey(sa.private_key)).toString('base64url');
  const res = await fetchImpl(sa.token_uri || 'https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${head}.${sig}` }),
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) throw new Error(`oauth ${res.status}`);
  const j = await res.json();
  return { token: j.access_token, until: now + (j.expires_in || 3600) * 1000 - 60000 };
}

/** One APNs request on its own HTTP/2 session; the whole exchange, connect included, is bounded. */
export function apnsPost(req, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    const s = http2.connect(req.host);
    const fail = (e) => { s.destroy(); reject(e); };
    s.setTimeout(timeoutMs, () => fail(new Error('apns timed out')));
    s.on('error', fail);
    const r = s.request({ ':method': 'POST', ':path': req.path, ...req.headers });
    let status = 0, text = '';
    r.on('response', (h) => { status = h[':status']; });
    r.setEncoding('utf8').on('data', (c) => { text += c; });
    r.on('end', () => { s.close(); resolve({ status, text }); });
    r.on('error', fail);
    r.end(req.body);
  });
}

const read = (file) => { try { return fs.readFileSync(file, 'utf8'); } catch { return null; } };

/**
 * Push sender for one config dir. `apns.json` {keyFile, keyId, teamId, bundleId} and
 * `fcm.json` (the service account) switch each side on; `devices` come from watcher.json.
 * shortcut: a new HTTP/2 connection per send, reuse it if sends get frequent.
 */
export function pushSender(dir, { fetchImpl = fetch, post = apnsPost, log = () => {} } = {}) {
  let fcm = { token: null, until: 0 };
  return async function send(devices, msg) {
    const p = toPush(msg);
    const apns = (() => { try { return JSON.parse(read(path.join(dir, 'apns.json'))); } catch { return null; } })();
    const sa = (() => { try { return JSON.parse(read(path.join(dir, 'fcm.json'))); } catch { return null; } })();
    await Promise.all((devices || []).map(async (d) => {
      try {
        if (d.platform === 'ios' && apns) {
          const pem = read(path.resolve(dir, apns.keyFile || 'apns.p8'));
          if (!pem) return log('apns: key file missing');
          const res = await post(apnsRequest(apns, d, p, cachedJwt(pem, apns.keyId, apns.teamId)));
          if (res.status !== 200) log('apns refused:', res.status, res.text); else log('apns sent', p.category);
        } else if (d.platform === 'android' && sa) {
          if (fcm.until <= Date.now()) fcm = await fcmAccessToken(sa, { fetchImpl });
          const res = await fetchImpl(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
            method: 'POST', headers: { authorization: `Bearer ${fcm.token}`, 'content-type': 'application/json' },
            body: JSON.stringify(fcmMessage(d, p)), signal: AbortSignal.timeout(10000),
          });
          if (!res.ok) log('fcm refused:', res.status, await res.text().catch(() => '')); else log('fcm sent', p.category);
        }
      } catch (e) { log('push failed:', d.platform, e.message); }
    }));
  };
}

// ---- Live Activity (iOS): what needs you and what is working, pushed to the lock screen ----

const WORKING_WINDOW_MS = 3 * 60000;
const END_AFTER_EMPTY_MS = 10 * 60000;

/** A rig agent (not a shell) that is running and whose last reply or hook event is recent. Never the pane's own redraw time. */
export function isWorking(node, now = Date.now()) {
  if (node.nodeKind !== 'agent' || node.runtime === 'terminal') return false;
  if (node.agentActivity?.state !== 'running') return false;
  const at = Math.max(...[node.modelObservation?.observedAt, node.agentActivity?.eventAt].map((t) => Date.parse(t) || 0));
  return now - at < WORKING_WINDOW_MS;
}

/**
 * Per provider, the freshest five-hour and weekly readings from the daemon's `hostUsage` (same rule as the app's home rings),
 * two providers at most. `h5Ahead`/`wkAhead` are how many points that window is over even pace (negative: under). `asOf` is epoch seconds of the freshest of the two. A provider whose freshest reading is over 15 min old is left out:
 * the card only redraws on a push, so the widget could never dim it by itself.
 */
const WINDOW_SECONDS = { five_hour: 18000, weekly: 604800 };

/** Percent points used over even pace (negative: under), the home rings' rule: pace = how far through the window we are. Null when unknown. */
function aheadOfPace(reading, window, now) {
  if (!reading || !Number.isFinite(reading.resetsAt)) return null;
  const pace = Math.min(Math.max(1 - (reading.resetsAt - now) / (WINDOW_SECONDS[window] * 1000), 0), 1);
  return reading.pct - Math.round(pace * 100);
}

export function usageSummary(hostUsage, now = Date.now()) {
  const byProvider = new Map();
  for (const u of Array.isArray(hostUsage) ? hostUsage : []) {
    const p = byProvider.get(u.provider) || {};
    for (const w of Array.isArray(u.windows) ? u.windows : []) {
      if (!['five_hour', 'weekly'].includes(w.window) || typeof w.usedPercent !== 'number') continue;
      const at = Date.parse(w.asOf) || 0;
      if (!p[w.window] || at > p[w.window].at) p[w.window] = { pct: Math.round(w.usedPercent), at, resetsAt: Date.parse(w.resetsAt) };
    }
    byProvider.set(u.provider, p);
  }
  const fresh = (p) => now - Math.max(p.five_hour?.at || 0, p.weekly?.at || 0) <= 15 * 60000;
  return [...byProvider].filter(([name, p]) => name && (p.five_hour || p.weekly) && fresh(p)).sort(([a], [b]) => a.localeCompare(b)).slice(0, 2).map(([provider, p]) => ({
    provider: provider[0].toUpperCase() + provider.slice(1), // a label to show as is: Claude, Codex
    h5: p.five_hour?.pct ?? null, wk: p.weekly?.pct ?? null,
    h5Ahead: aheadOfPace(p.five_hour, 'five_hour', now), wkAhead: aheadOfPace(p.weekly, 'weekly', now),
    asOf: Math.floor(Math.max(p.five_hour?.at || 0, p.weekly?.at || 0) / 1000),
  }));
}

/** The content state of PUSH.md §4: totals, the active rigs (at most 3) with their need-you and working counts, and provider usage. */
export function activityContent(seats, now = Date.now(), usage = []) {
  const rigs = new Map();
  let needsCount = 0, workingCount = 0;
  for (const s of seats.filter((x) => x.agent)) {
    const needs = s.waiting, working = !s.waiting && s.working;
    if (!needs && !working) continue;
    needsCount += needs ? 1 : 0;
    workingCount += working ? 1 : 0;
    const k = s.key.split('/')[0]; // the rig id: two rigs may share a name
    const r = rigs.get(k) || { project: s.project || null, rig: s.rigName, needs: 0, working: 0 };
    r.needs += needs ? 1 : 0;
    r.working += working ? 1 : 0;
    rigs.set(k, r);
  }
  const sorted = [...rigs.values()].sort((a, b) => b.needs - a.needs || b.working - a.working || a.rig.localeCompare(b.rig));
  return { needsCount, workingCount, rigs: sorted.slice(0, 3), rigCount: sorted.length, usage, updatedAt: Math.floor(now / 1000) };
}

/**
 * The `liveactivity` request that starts (push-to-start token), updates or ends an activity. Priority 10 is budgeted by iOS
 * and was used for every update (about 700 a day, up to 10 a minute): an update that is not [urgent] (nothing newly needs you)
 * goes at 5, which the system may delay but does not count against the budget that a start or a new ask needs.
 */
export function activityRequest(apns, device, event, token, content, attributes, jwt, now = Date.now(), urgent = true) {
  const ts = Math.floor(now / 1000);
  const aps = { timestamp: ts, event, 'content-state': content };
  if (event === 'start') {
    Object.assign(aps, { 'attributes-type': 'PocketRigAttributes', attributes, alert: { title: 'Pocket Rig', body: 'Agents need you or are working' } });
  }
  if (event === 'end') aps['dismissal-date'] = ts;
  return {
    host: device.env === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com',
    path: `/3/device/${token}`,
    headers: { authorization: `bearer ${jwt}`, 'apns-topic': `${apns.bundleId}.push-type.liveactivity`, 'apns-push-type': 'liveactivity', 'apns-priority': event === 'update' && !urgent ? '5' : '10' },
    body: JSON.stringify({ aps }),
  };
}

/**
 * Keeps one Live Activity per phone in step with [content]: starts it with the push-to-start
 * token when something needs you or works, updates it through its own token when that changes,
 * ends it when both lists are empty. The app reports the tokens into watcher.json.
 * shortcut: one activity per phone, so two hosts pushing to one phone take turns overwriting it.
 */
export function liveActivityDriver(dir, { post = apnsPost, log = () => {}, now = () => Date.now() } = {}) {
  const phones = new Map(); // push-to-start token → { active, sentKey, deadToken, started, reported }
  const starts = new Map(); // start id (in the tokenUrl the phone got) → that phone's state
  async function run(devices, content, host, answer) {
    const apns = (() => { try { return JSON.parse(read(path.join(dir, 'apns.json'))); } catch { return null; } })();
    const pem = apns && read(path.resolve(dir, apns.keyFile || 'apns.p8'));
    if (!pem) return;
    const any = content.needsCount > 0 || content.workingCount > 0;
    const key = JSON.stringify([content.needsCount, content.workingCount, content.rigs]); // usage rides along, it never causes a push
    for (const d of (devices || []).filter((x) => x.platform === 'ios' && x.activityStartToken)) {
      const st = phones.get(d.activityStartToken) || { active: false, sentKey: null, deadToken: null, started: false, startedAt: 0, retryAt: 0, reported: null, startId: null, own: false, emptySince: null };
      phones.set(d.activityStartToken, st);
      const jwt = cachedJwt(pem, apns.keyId, apns.teamId);
      const send = async (event, token, attributes) => {
        try {
          const urgent = content.needsCount > (st.sentNeeds ?? 0); // someone newly needs you
          const res = await post(activityRequest(apns, d, event, token, content, attributes, jwt, now(), urgent));
          const status = res.status;
          if (status === 200) { log('live activity', event, 'sent'); st.sentNeeds = content.needsCount; } else log('live activity', event, 'answered', status, (() => { try { return JSON.parse(res.text).reason; } catch { return ''; } })() || '');
          return status;
        } catch (e) { log('live activity failed:', e.message); return 0; }
      };
      // The phone's own report (the app may be closed) beats what the app last wrote into watcher.json.
      // Once this watcher has started an activity, only the phone's own report names its token: watcher.json still holds the previous one.
      const tok = st.own ? st.reported : d.activityToken;
      const live = tok && tok !== st.deadToken ? tok : null;
      if (!any) {
        if (!live) { st.active = false; st.sentKey = null; st.emptySince = null; continue; }
        // Agents flick idle and busy: end only after the lists stay empty a while, or iOS may throttle the start/end pushes.
        st.emptySince ??= now();
        if (now() - st.emptySince >= END_AFTER_EMPTY_MS) {
          await send('end', live);
          Object.assign(st, { deadToken: live, started: false, active: false, sentKey: null, emptySince: null });
        } else if (st.sentKey !== key && await send('update', live) === 200) st.sentKey = key; // meanwhile the card says what is true
        continue;
      }
      st.emptySince = null; // they came back: cancel the end
      if (live) {
        if (st.active && st.sentKey === key) continue;
        const status = await send('update', live);
        if (status === 200) { st.active = true; st.sentKey = key; continue; }
        if (!status) continue; // APNs unreachable: try again at the next check
        st.deadToken = live; st.started = false; // the activity is gone: start another
      }
      // Started, its token not here yet (or the person turned activities off): a second start would stack another on the lock screen.
      // Fallback: after 2 h without a token the start probably never showed.
      if (st.started && now() - st.startedAt < 2 * 3600e3) continue;
      if (now() < st.retryAt) continue; // refused: waits (server trouble) or stays off (this token is dead; a new token is a new entry)
      st.started = true;
      st.startedAt = now();
      st.reported = null; // a new activity: the old token is not its token
      st.own = Boolean(answer); // without a tokenUrl the phone can never report, so watcher.json's token is all there is
      // The phone posts the new activity's token to tokenUrl; the ticket proves it is for this start.
      const id = randomBytes(8).toString('hex');
      starts.delete(st.startId); // only the newest start of a phone may report: a late post for an old activity must not steal the new one's updates
      st.startId = id;
      starts.set(id, st);
      const attributes = { host, ...(answer ? { tokenUrl: `${answer.url}?start=${id}`, ticket: answer.sign(id) } : {}) };
      const status = await send('start', d.activityStartToken, attributes);
      if (status === 200) { st.active = true; st.sentKey = key; } else {
        st.started = false;
        if (status) { st.retryAt = status >= 500 || status === 429 ? now() + 5 * 60000 : Infinity; log('live activity start refused:', status); }
      }
    }
  }
  // One drive at a time; calls that arrive meanwhile collapse into one rerun with the newest state, so a slow APNs builds no backlog.
  let running = null, next = null;
  const go = () => {
    running = run(...next.args).finally(() => {
      running = null;
      if (next.queued) { const n = next; next = null; drive(...n.args).catch(() => {}); } else next = null;
    });
    return running;
  };
  function drive(...args) {
    if (!running) { next = { args, queued: false }; return go(); }
    next = { args, queued: true };
    return running;
  }
  /** The phone reported an activity token for start [id]: true when this watcher made that start. */
  drive.report = (id, token) => {
    const st = starts.get(id);
    if (!st) return false;
    st.reported = token;
    return true;
  };
  return drive;
}
