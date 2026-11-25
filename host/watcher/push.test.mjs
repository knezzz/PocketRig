// node --test host/watcher/push.test.mjs
import assert from 'node:assert/strict';
import { generateKeyPairSync, createVerify, verify } from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import { apnsJwt, apnsPost, apnsRequest, fcmAccessToken, fcmMessage, pushSender, toPush } from './push.mjs';
import { publish, seatMessage } from './pocketrig-watcher.mjs';

const cfg = { topic: 't', hostName: 'homelab', answerBase: 'http://h:7434', answerToken: 'tok', kinds: new Set() };
const lead = { rigName: 'conveyor', project: 'app', logicalId: 'lead', session: 'lead@conveyor', reason: 'Bash: npm test', waiting: true };
const dec = (s) => JSON.parse(Buffer.from(s, 'base64url'));

test('a permission ask becomes a push with allow/deny buttons that carry the ticket body', () => {
  const p = toPush(seatMessage(cfg, lead, 'pr-seat-1'));
  assert.equal(p.category, 'pr-permission');
  assert.deepEqual(p.actions.map((a) => a.id), ['allow', 'deny']);
  assert.equal(p.actions[0].url, 'http://h:7434/answer');
  assert.ok(JSON.parse(p.actions[0].body).ticket);
  assert.equal(p.seq, 'pr-seat-1');
  assert.match(p.link, /^pocketrig:\/\/seat\//);
  assert.match(p.title, /lead needs approval/);
});

test('questions, results and unanswerable asks pick the right category', () => {
  const q = toPush(seatMessage({ ...cfg, answerBase: null }, { ...lead, reason: 'question: which db?' }));
  assert.ok(['pr-question', 'pr-blocked'].includes(q.category));
  assert.deepEqual(q.actions, []);
  assert.equal(toPush({ title: 'ok', message: 'm', priority: 2 }).category, 'pr-result');
  assert.equal(toPush({ title: 'ok', message: 'm', priority: 2 }).ask, false);
});

test('APNs: ES256 JWT verifies, the request collapses by seq and targets the right gateway', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const jwt = apnsJwt(pem, 'KEY1', 'TEAM1', 1_700_000_000_000);
  const [h, c, s] = jwt.split('.');
  assert.deepEqual(dec(h), { alg: 'ES256', kid: 'KEY1' });
  assert.deepEqual(dec(c), { iss: 'TEAM1', iat: 1_700_000_000 });
  assert.ok(verify('sha256', Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url')));
  const p = toPush(seatMessage(cfg, lead, 'pr-seat-1'));
  const r = apnsRequest({ bundleId: 'dev.pocketrig.pocketRig' }, { platform: 'ios', token: 'abc', env: 'sandbox' }, p, jwt);
  assert.equal(r.host, 'https://api.sandbox.push.apple.com');
  assert.equal(r.path, '/3/device/abc');
  assert.equal(r.headers['apns-collapse-id'], 'pr-seat-1');
  assert.equal(r.headers['apns-topic'], 'dev.pocketrig.pocketRig');
  const body = JSON.parse(r.body);
  assert.equal(body.aps.category, 'pr-permission');
  assert.equal(body.aps['thread-id'], 'pr-seat-1');
  assert.equal(JSON.parse(body.actions).length, 2);
  assert.equal(apnsRequest({ bundleId: 'x' }, { token: 'abc', env: 'production' }, p, jwt).host, 'https://api.push.apple.com');
});

test('FCM: data-only message with collapse key; OAuth token from a signed service-account JWT', async () => {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const sa = { client_email: 'svc@p.iam.gserviceaccount.com', private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }), project_id: 'proj' };
  let seen;
  const fetchImpl = async (url, init) => { seen = { url, init }; return { ok: true, json: async () => ({ access_token: 'AT', expires_in: 3600 }) }; };
  const t = await fcmAccessToken(sa, { fetchImpl, now: 1_700_000_000_000 });
  assert.equal(t.token, 'AT');
  const assertion = seen.init.body.get('assertion');
  const [h, c, s] = assertion.split('.');
  assert.equal(dec(c).iss, sa.client_email);
  assert.equal(dec(c).exp - dec(c).iat, 3600);
  assert.ok(createVerify('RSA-SHA256').update(`${h}.${c}`).verify(publicKey, Buffer.from(s, 'base64url')));
  const m = fcmMessage({ token: 'dev' }, toPush(seatMessage(cfg, lead, 'pr-seat-1'))).message;
  assert.equal(m.token, 'dev');
  assert.equal(m.android.collapse_key, 'pr-seat-1');
  assert.ok(Object.values(m.data).every((v) => typeof v === 'string'));
  assert.equal(m.notification, undefined);
});

test('the sender pushes each device through its own service and one failure does not stop the other', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-push-'));
  const ec = generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' });
  const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ type: 'pkcs8', format: 'pem' });
  fs.writeFileSync(path.join(dir, 'apns.p8'), ec);
  fs.writeFileSync(path.join(dir, 'apns.json'), JSON.stringify({ keyId: 'K', teamId: 'T', bundleId: 'b.id' }));
  fs.writeFileSync(path.join(dir, 'fcm.json'), JSON.stringify({ client_email: 'e', private_key: rsa, project_id: 'proj' }));
  const calls = [], logs = [];
  const fetchImpl = async (url, init) => {
    calls.push(url);
    return url.includes('oauth') ? { ok: true, json: async () => ({ access_token: 'AT' }) } : { ok: true };
  };
  const send = pushSender(dir, { fetchImpl, post: async () => { throw new Error('apns down'); }, log: (...a) => logs.push(a.join(' ')) });
  await send([{ platform: 'ios', token: 'a', env: 'sandbox' }, { platform: 'android', token: 'f' }], seatMessage(cfg, lead, 'pr-seat-1'));
  assert.ok(calls.some((u) => u.endsWith('/projects/proj/messages:send')));
  assert.ok(logs.some((l) => l.includes('apns down')));
  // no key files, nothing sent
  const none = [];
  await pushSender(fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-push-')), { fetchImpl: async (u) => { none.push(u); return { ok: true }; } })([{ platform: 'android', token: 'f' }], { title: 't' });
  assert.deepEqual(none, []);
});

test('a push that never answers does not hold up ntfy', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-push-'));
  fs.writeFileSync(path.join(dir, 'fcm.json'), JSON.stringify({ client_email: 'e', private_key: generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ type: 'pkcs8', format: 'pem' }), project_id: 'proj' }));
  const urls = [];
  const fetchImpl = (url) => { urls.push(url); return url.includes('ntfy.test') ? Promise.resolve({ ok: true, text: async () => '' }) : new Promise(() => {}); };
  const ok = await publish({ ...cfg, dir, server: 'https://ntfy.test', devices: [{ platform: 'android', token: 'f' }] }, { title: 't', message: 'm' }, { fetchImpl });
  assert.equal(ok, true);
  assert.ok(urls.some((u) => u.includes('oauth2.googleapis.com')), 'push was started');
});

test('APNs: a host that accepts the connection but never answers is dropped at the timeout', async () => {
  const server = net.createServer(() => {}); // takes the socket, says nothing
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const started = Date.now();
  await assert.rejects(apnsPost({ host: `http://127.0.0.1:${server.address().port}`, path: '/3/device/x', headers: {}, body: '{}' }, 200), /timed out/);
  assert.ok(Date.now() - started < 2000);
  server.close();
});

test('the APNs JWT is made once for many sends', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-push-'));
  fs.writeFileSync(path.join(dir, 'apns.p8'), generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' }));
  fs.writeFileSync(path.join(dir, 'apns.json'), JSON.stringify({ keyId: 'K', teamId: 'T', bundleId: 'b.id' }));
  const auth = [];
  const send = pushSender(dir, { post: async (r) => { auth.push(r.headers.authorization); return { status: 200 }; } });
  for (let i = 0; i < 3; i++) await send([{ platform: 'ios', token: 'a' }], { title: 't' });
  assert.equal(new Set(auth).size, 1);
});

test('a long ask stays far under the 4 KB APNs limit', () => {
  const p = toPush({ title: 'x'.repeat(5000), message: 'y'.repeat(50000), priority: 4 });
  assert.ok(JSON.parse(apnsRequest({ bundleId: 'b' }, { token: 't' }, p, 'jwt').body).aps.alert.body.length <= 1000);
  assert.ok(apnsRequest({ bundleId: 'b' }, { token: 't' }, p, 'jwt').body.length < 2500);
});

import { activityContent, activityRequest, isWorking, liveActivityDriver, usageSummary } from './push.mjs';

test('working means a running agent with a recent reply or hook event, never a shell or a pane redraw', () => {
  const now = Date.parse('2026-11-18T00:10:00Z');
  const agent = (over) => ({ nodeKind: 'agent', runtime: 'claude-code', agentActivity: { state: 'running', eventAt: '2026-11-18T00:09:00Z' }, ...over });
  assert.equal(isWorking(agent({}), now), true);
  assert.equal(isWorking(agent({ agentActivity: { state: 'running', eventAt: '2026-11-18T00:01:00Z' }, lastActivityAt: '2026-11-18T00:09:59Z' }), now), false, 'pane time does not count');
  assert.equal(isWorking(agent({ modelObservation: { observedAt: '2026-11-18T00:09:30Z' }, agentActivity: { state: 'running', eventAt: '2026-11-18T00:01:00Z' } }), now), true, 'a recent reply counts');
  assert.equal(isWorking(agent({ agentActivity: { state: 'idle', eventAt: '2026-11-18T00:09:59Z' } }), now), false);
  assert.equal(isWorking(agent({ runtime: 'terminal' }), now), false);
  assert.equal(isWorking(agent({ nodeKind: 'infrastructure' }), now), false);
});

test('content state: totals, the active rigs with their counts (three at most, biggest need first), shells left out', () => {
  const s = (rigId, rig, id, over) => ({ agent: true, key: `${rigId}/${id}`, logicalId: id, rigName: rig, project: 'p', session: `${id}@${rig}`, waiting: false, working: false, ...over });
  const seats = [
    s('r1', 'quiet', 'q'), // idle: not active
    s('r2', 'alpha', 'a1', { working: true }), s('r2', 'alpha', 'a2', { working: true }), s('r2', 'alpha', 'a3', { working: true }),
    s('r3', 'zeta', 'z1', { waiting: true, working: true }), s('r3', 'zeta', 'z2', { working: true }),
    s('r4', 'beta', 'b1', { waiting: true }), s('r4', 'beta', 'b2', { waiting: true }),
    s('r5', 'twin', 't1', { working: true, project: null }), s('r6', 'twin', 't2', { working: true, project: 'q' }),
    s('r7', 'shell', 'sh', { agent: false, waiting: true }),
  ];
  const c = activityContent(seats, 1_700_000_000_000, [{ provider: 'Claude', h5: 4, wk: null, asOf: 5 }]);
  assert.equal(c.needsCount, 3);
  assert.equal(c.workingCount, 6, 'a need-you agent is not also working');
  assert.deepEqual(c.rigs, [
    { project: 'p', rig: 'beta', needs: 2, working: 0 },
    { project: 'p', rig: 'zeta', needs: 1, working: 1 },
    { project: 'p', rig: 'alpha', needs: 0, working: 3 },
  ]);
  assert.equal(c.rigCount, 5, 'quiet rigs and shells are not active; twin counts as two rigs');
  assert.deepEqual(c.usage, [{ provider: 'Claude', h5: 4, wk: null, asOf: 5 }]);
  assert.equal(c.updatedAt, 1_700_000_000);
  assert.equal(c.needs, undefined);
  assert.deepEqual(activityContent([], 1000), { needsCount: 0, workingCount: 0, rigs: [], rigCount: 0, usage: [], updatedAt: 1 });
});

test('usage: ahead is signed points over even pace, the home rings\' rule', () => {
  const now = Date.parse('2026-11-19T19:56:00Z');
  const row = (window, usedPercent, resetsInMs) => ({ host: 'local', provider: 'claude', windows: [{ window, usedPercent, resetsAt: new Date(now + resetsInMs).toISOString(), asOf: new Date(now).toISOString() }] });
  const h5 = (used, resetsInMs = 2.5 * 3600e3) => usageSummary([row('five_hour', used, resetsInMs)], now)[0].h5Ahead; // 2.5 h left of 5 h: pace 50%
  assert.equal(h5(60), 10);
  assert.equal(h5(50), 0);
  assert.equal(h5(10), -40, 'under pace is negative');
  assert.equal(h5(100, -60000), 0, 'window already over: pace 100%');
  assert.equal(h5(5, 99 * 3600e3), 5, 'a reset further out than the window: pace 0%');
  assert.equal(h5(19.4), -31, 'the rounded used percent, as the app does');
  const wk = usageSummary([row('weekly', 40, 3.5 * 86400e3)], now)[0];
  assert.deepEqual([wk.wk, wk.wkAhead, wk.h5Ahead], [40, -10, null], 'weekly pace 50%; the missing window stays null');
});

test('usage: the freshest reading per window, a label to show, nothing stale, two providers at most', () => {
  const w = (window, usedPercent, asOf) => ({ window, usedPercent, resetsAt: 'x', asOf });
  const rows = [
    { host: 'local', provider: 'claude', windows: [w('five_hour', 19.4, '2026-11-19T19:50:00Z'), w('weekly', 11, '2026-11-19T19:00:00Z'), w('monthly', 99, '2026-11-19T19:59:00Z')] },
    { host: 'local', provider: 'claude', windows: [w('five_hour', 1, '2026-11-19T19:40:00Z'), w('weekly', 15.6, '2026-11-19T19:55:00Z')] },
    { host: 'local', provider: 'codex', windows: [w('weekly', 30, '2026-11-19T19:50:00Z')] },
    { host: 'local', provider: 'gemini', windows: [w('weekly', 5, '2026-11-19T19:51:00Z')] },
    { host: 'local', provider: 'old', windows: [w('weekly', 5, '2026-11-19T19:30:00Z')] },
    { host: 'local', provider: 'empty', windows: [] },
  ];
  const at = Date.parse('2026-11-19T19:56:00Z');
  assert.deepEqual(usageSummary(rows, at), [
    { provider: 'Claude', h5: 19, wk: 16, h5Ahead: null, wkAhead: null, asOf: Date.parse('2026-11-19T19:55:00Z') / 1000 },
    { provider: 'Codex', h5: null, wk: 30, h5Ahead: null, wkAhead: null, asOf: Date.parse('2026-11-19T19:50:00Z') / 1000 },
  ], 'two providers at most; the 26-minute-old one never shows');
  assert.deepEqual(usageSummary(rows, Date.parse('2026-11-19T20:20:00Z')), [], 'a quiet phone: everything is over 15 min old');
  assert.deepEqual(usageSummary(undefined), []);
});

test('Live Activity: start with the push-to-start token, update through the activity token, end when empty', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-push-'));
  fs.writeFileSync(path.join(dir, 'apns.p8'), generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' }));
  fs.writeFileSync(path.join(dir, 'apns.json'), JSON.stringify({ keyId: 'K2', teamId: 'T2', bundleId: 'b.id' }));
  const sent = [];
  let clock = 1_000_000, status = 200, attrs;
  const drive = liveActivityDriver(dir, { post: async (r) => { const aps = JSON.parse(r.body).aps; attrs = aps.attributes; sent.push([aps.event, r.path]); return { status }; }, now: () => clock });
  const ans = { url: 'http://h:7434/activity-token', sign: (x) => x };
  const startId = () => new URL(attrs.tokenUrl).searchParams.get('start');
  const dev = { platform: 'ios', token: 'alert', env: 'sandbox', activityStartToken: 'S1' };
  const one = { needs: [{ role: 'a', rig: 'r', project: 'p', session: 'a@r' }], needsCount: 1, workingCount: 0, updatedAt: 1 };
  const none = { needs: [], needsCount: 0, workingCount: 0, updatedAt: 2 };
  await drive([dev], none, 'h', ans);
  assert.deepEqual(sent, [], 'nothing to show, nothing started');
  await drive([dev], one, 'h', ans);
  clock += 1000;
  await drive([dev], one, 'h', ans);
  for (let i = 0; i < 12; i++) { clock += 60000; await drive([dev], one, 'h', ans); }
  assert.deepEqual(sent, [['start', '/3/device/S1']], 'no second start while the app has not reported its token');
  assert.equal(drive.report(startId(), 'A1'), true); // the phone says which activity the start made
  const live = dev;
  await drive([live], one, 'h', ans);
  assert.equal(sent.length, 1, 'the start already carried these lists');
  const two = { ...one, workingCount: 1 };
  await drive([live], two, 'h', ans);
  assert.deepEqual(sent.at(-1), ['update', '/3/device/A1']);
  await drive([live], two, 'h', ans);
  assert.equal(sent.length, 2, 'unchanged lists send nothing');
  await drive([live], none, 'h', ans);
  assert.deepEqual(sent.at(-1), ['update', '/3/device/A1'], 'empty: the card says so, but stays for now');
  clock += 10 * 60000;
  await drive([live], none, 'h', ans);
  assert.deepEqual(sent.at(-1), ['end', '/3/device/A1']);
  await drive([live], none, 'h', ans);
  assert.equal(sent.length, 4, 'ended once');
  // start request carries the attributes and the content
  const rq = JSON.parse(activityRequest({ bundleId: 'b.id' }, dev, 'start', 'S1', one, { host: 'h' }, 'jwt', 5000).body).aps;
  assert.equal(rq['attributes-type'], 'PocketRigAttributes');
  assert.deepEqual(rq.attributes, { host: 'h' });
  // a dead activity token (410) falls back to a fresh start
  clock += 120000;
  await drive([dev], one, 'h', ans);
  drive.report(startId(), 'A2');
  status = 410;
  await drive([dev], two, 'h', ans);
  status = 200;
  assert.deepEqual(sent.slice(-2).map((x) => x[0]), ['update', 'start']);
});

test('Live Activity: overlapping drives start once; an app that never reports a token gets a retry after 2 h', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-push-'));
  fs.writeFileSync(path.join(dir, 'apns.p8'), generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' }));
  fs.writeFileSync(path.join(dir, 'apns.json'), JSON.stringify({ keyId: 'K3', teamId: 'T3', bundleId: 'b.id' }));
  let starts = 0, clock = 5_000_000;
  const drive = liveActivityDriver(dir, { post: async () => { starts++; await new Promise((r) => setTimeout(r, 20)); return { status: 200 }; }, now: () => clock });
  const dev = { platform: 'ios', token: 't', env: 'sandbox', activityStartToken: 'S9' };
  const one = { needs: [{ role: 'a', rig: 'r', project: 'p', session: 'a@r' }], needsCount: 1, workingCount: 0, updatedAt: 1 };
  await Promise.all([drive([dev], one, 'h'), drive([dev], one, 'h'), drive([dev], one, 'h')]);
  assert.equal(starts, 1);
  clock += 3 * 3600e3;
  await drive([dev], one, 'h');
  assert.equal(starts, 2);
});

test('Live Activity: a slow APNs builds no backlog, and a start refused for good stays off, server trouble retries after a wait', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-push-'));
  fs.writeFileSync(path.join(dir, 'apns.p8'), generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' }));
  fs.writeFileSync(path.join(dir, 'apns.json'), JSON.stringify({ keyId: 'K4', teamId: 'T4', bundleId: 'b.id' }));
  let posts = 0, clock = 9_000_000, status = 410;
  const drive = liveActivityDriver(dir, { post: async () => { posts++; await new Promise((r) => setTimeout(r, 20)); return { status }; }, now: () => clock });
  const dev = { platform: 'ios', token: 't', env: 'sandbox', activityStartToken: 'S7' };
  const state = (n) => ({ needs: Array.from({ length: n }, (_, i) => ({ role: `r${i}`, rig: 'r', session: `r${i}@r` })), needsCount: n, workingCount: 0, updatedAt: 1 });
  await Promise.all([1, 2, 3, 4, 5].map((n) => drive([dev], state(n), 'h')));
  await new Promise((r) => setTimeout(r, 100));
  assert.equal(posts, 1, 'the 410 is final for this token, so the queued rerun sends nothing');
  clock += 6 * 3600e3;
  await drive([dev], state(1), 'h');
  assert.equal(posts, 1);
  status = 503;
  const flaky = { ...dev, activityStartToken: 'S8' };
  await drive([flaky], state(1), 'h');
  await drive([flaky], state(1), 'h');
  assert.equal(posts, 2, 'a 503 waits');
  clock += 6 * 60000;
  status = 200;
  await drive([flaky], state(1), 'h');
  assert.equal(posts, 3, 'then tries again');
});

test('Live Activity: the start carries a token url and ticket, and the phone\'s own report drives the updates', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-push-'));
  fs.writeFileSync(path.join(dir, 'apns.p8'), generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' }));
  fs.writeFileSync(path.join(dir, 'apns.json'), JSON.stringify({ keyId: 'K5', teamId: 'T5', bundleId: 'b.id' }));
  const sent = [];
  let clock = 1_000_000;
  const drive = liveActivityDriver(dir, { post: async (r) => { sent.push({ event: JSON.parse(r.body).aps.event, path: r.path, aps: JSON.parse(r.body).aps }); return { status: 200 }; }, now: () => clock });
  const dev = { platform: 'ios', token: 't', env: 'sandbox', activityStartToken: 'S5' };
  const one = { needs: [{ role: 'a', rig: 'r', project: 'p', session: 'a@r' }], needsCount: 1, workingCount: 0, updatedAt: 1 };
  const two = { ...one, workingCount: 1 };
  const answer = { url: 'http://h:7434/activity-token', sign: (id) => `sig-${id}` };
  await drive([dev], one, 'h', answer);
  const { tokenUrl, ticket: tk, host } = sent[0].aps.attributes;
  assert.equal(host, 'h');
  const id = new URL(tokenUrl).searchParams.get('start');
  assert.match(tokenUrl, /^http:\/\/h:7434\/activity-token\?start=[0-9a-f]{16}$/);
  assert.equal(tk, `sig-${id}`);
  assert.equal(drive.report('nope', 'aa'), false, 'an id this driver never made');
  assert.equal(drive.report(id, 'A9A9A9A9A9A9A9A9'), true);
  await drive([dev], two, 'h', answer); // no activityToken in watcher.json: the report is enough
  assert.deepEqual([sent.at(-1).event, sent.at(-1).path], ['update', '/3/device/A9A9A9A9A9A9A9A9']);
  await drive([dev], { needs: [], needsCount: 0, workingCount: 0, updatedAt: 3 }, 'h', answer);
  assert.equal(sent.at(-1).event, 'update');
  await drive([dev], { needs: [], needsCount: 0, workingCount: 0, updatedAt: 4 }, 'h', answer);
  assert.equal(sent.at(-1).event, 'update', 'still inside the grace period');
  clock += 10 * 60000;
  await drive([dev], { needs: [], needsCount: 0, workingCount: 0, updatedAt: 5 }, 'h', answer);
  assert.deepEqual([sent.at(-1).event, sent.at(-1).path], ['end', '/3/device/A9A9A9A9A9A9A9A9']);
  // A second activity starts; a late report for the first one must not take it over.
  await drive([dev], one, 'h', answer);
  const id2 = new URL(sent.at(-1).aps.attributes.tokenUrl).searchParams.get('start');
  assert.notEqual(id2, id);
  assert.equal(drive.report(id, 'DEADDEADDEADDEAD'), false, 'an old start is unknown now');
  assert.equal(drive.report(id2, 'B1B1B1B1B1B1B1B1'), true);
  await drive([dev], two, 'h', answer);
  assert.equal(sent.at(-1).path, '/3/device/B1B1B1B1B1B1B1B1');
});

test('Live Activity: after a fresh start only the phone-reported token is used, never the older one in watcher.json', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-push-'));
  fs.writeFileSync(path.join(dir, 'apns.p8'), generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' }));
  fs.writeFileSync(path.join(dir, 'apns.json'), JSON.stringify({ keyId: 'K7', teamId: 'T7', bundleId: 'b.id' }));
  const sent = [];
  const drive = liveActivityDriver(dir, { post: async (r) => { sent.push([JSON.parse(r.body).aps.event, r.path, JSON.parse(r.body).aps.attributes]); return { status: 200 }; } });
  const stale = 'DEADDEADDEADDEAD';
  const dev = { platform: 'ios', token: 't', env: 'sandbox', activityStartToken: 'S8', activityToken: stale };
  const state = (n) => ({ needs: [], needsCount: n, workingCount: 0, rigs: [], rigCount: 0, usage: [], updatedAt: 1 });
  const answer = { url: 'http://h:7434/activity-token', sign: (id) => id };
  // Not started by this watcher yet: watcher.json's token is the best there is (an activity the app started).
  await drive([dev], state(1), 'h', answer);
  assert.deepEqual(sent.at(-1).slice(0, 2), ['update', `/3/device/${stale}`]);
  // The activity dies; this watcher starts its own.
  await drive([{ ...dev, activityToken: undefined }], state(2), 'h', answer); // 410-less: force a start by dropping the token
  assert.equal(sent.at(-1)[0], 'start');
  const id = new URL(sent.at(-1)[2].tokenUrl).searchParams.get('start');
  const n = sent.length;
  await drive([dev], state(3), 'h', answer); // watcher.json still says `stale`
  assert.equal(sent.length, n, 'no update to the old activity, no second start: the new activity has not reported yet');
  drive.report(id, 'FEEDFEEDFEEDFEED');
  await drive([dev], state(4), 'h', answer);
  assert.deepEqual(sent.at(-1).slice(0, 2), ['update', '/3/device/FEEDFEEDFEEDFEED']);
});

test('Live Activity: it ends only after the lists stay empty for ten minutes, and coming back cancels the end', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-push-'));
  fs.writeFileSync(path.join(dir, 'apns.p8'), generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' }));
  fs.writeFileSync(path.join(dir, 'apns.json'), JSON.stringify({ keyId: 'K8', teamId: 'T8', bundleId: 'b.id' }));
  const sent = [];
  let clock = 1_000_000, attrs;
  const drive = liveActivityDriver(dir, { post: async (r) => { const aps = JSON.parse(r.body).aps; attrs = aps.attributes; sent.push(aps.event); return { status: 200 }; }, now: () => clock });
  const dev = { platform: 'ios', token: 't', env: 'sandbox', activityStartToken: 'S9' };
  const ans = { url: 'http://h:7434/activity-token', sign: (x) => x };
  const st = (n, w) => ({ needs: [], needsCount: n, workingCount: w, rigs: [], rigCount: 0, usage: [], updatedAt: 1 });
  await drive([dev], st(0, 2), 'h', ans);
  drive.report(new URL(attrs.tokenUrl).searchParams.get('start'), 'A1');
  const min = async (m, s) => { clock += m * 60000; await drive([dev], s, 'h', ans); };
  await min(1, st(0, 0));   // agents went idle
  await min(5, st(0, 0));
  await min(1, st(0, 3));   // busy again: the end is cancelled
  await min(5, st(0, 0));   // idle again: the ten minutes start over
  await min(9, st(0, 0));
  assert.deepEqual(sent, ['start', 'update', 'update', 'update'], 'no end yet, and never a second start');
  await min(2, st(0, 0));
  assert.deepEqual(sent, ['start', 'update', 'update', 'update', 'end']);
  await min(1, st(0, 0));
  assert.equal(sent.length, 5, 'ended once');
  await min(1, st(1, 0));
  assert.equal(sent.at(-1), 'start', 'the next change starts a fresh card');
});

test('Live Activity: with no answer endpoint (no tokenUrl) the token from watcher.json is still used after a start', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-push-'));
  fs.writeFileSync(path.join(dir, 'apns.p8'), generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' }));
  fs.writeFileSync(path.join(dir, 'apns.json'), JSON.stringify({ keyId: 'K9', teamId: 'T9', bundleId: 'b.id' }));
  const sent = [];
  const drive = liveActivityDriver(dir, { post: async (r) => { sent.push([JSON.parse(r.body).aps.event, r.path]); return { status: 200 }; } });
  const dev = { platform: 'ios', token: 't', env: 'sandbox', activityStartToken: 'S10' };
  const st = (n) => ({ needs: [], needsCount: n, workingCount: 0, rigs: [], rigCount: 0, usage: [], updatedAt: 1 });
  await drive([dev], st(1), 'h', null);
  await drive([{ ...dev, activityToken: 'APP1' }], st(2), 'h', null); // the app wrote the token; nothing else can report it
  assert.deepEqual(sent.at(-1), ['update', '/3/device/APP1']);
});

test('Live Activity: an update where nobody newly needs you goes at priority 5, a start, an end and a new ask at 10; a refusal is logged with its reason', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-push-'));
  fs.writeFileSync(path.join(dir, 'apns.p8'), generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' }));
  fs.writeFileSync(path.join(dir, 'apns.json'), JSON.stringify({ keyId: 'K2', teamId: 'T2', bundleId: 'b.id' }));
  const sent = [], logged = [];
  let clock = 1_000_000, res = { status: 200, text: '' };
  const drive = liveActivityDriver(dir, { post: async (r) => { sent.push([JSON.parse(r.body).aps.event, r.headers['apns-priority']]); return res; }, log: (...a) => logged.push(a.join(' ')), now: () => clock });
  let attrs;
  const ans = { url: 'http://h:7434/activity-token', sign: (x) => { attrs = x; return x; } }; // the id of the newest start
  const dev = { platform: 'ios', token: 'alert', env: 'sandbox', activityStartToken: 'S1' };
  const c = (needsCount, workingCount) => ({ needsCount, workingCount, rigs: [{ rig: 'r', needs: needsCount, working: workingCount }], rigCount: 1, usage: [], updatedAt: 1 });
  await drive([dev], c(0, 1), 'h', ans);
  assert.deepEqual(sent.at(-1), ['start', '10']);
  drive.report(attrs, 'A1');
  await drive([dev], c(0, 2), 'h', ans);
  assert.deepEqual(sent.at(-1), ['update', '5'], 'one more agent working: no hurry');
  await drive([dev], c(1, 1), 'h', ans);
  assert.deepEqual(sent.at(-1), ['update', '10'], 'someone newly needs you');
  await drive([dev], c(0, 1), 'h', ans);
  assert.deepEqual(sent.at(-1), ['update', '5'], 'a need answered: no hurry');
  await drive([dev], c(0, 0), 'h', ans);
  clock += 10 * 60000;
  await drive([dev], c(0, 0), 'h', ans);
  assert.deepEqual(sent.at(-1), ['end', '10']);
  // not 200: what APNs said is in the log, not silently turned into a restart
  clock += 120000;
  await drive([dev], c(0, 1), 'h', ans);
  drive.report(attrs, 'A2');
  res = { status: 410, text: JSON.stringify({ reason: 'ExpiredToken' }) };
  await drive([dev], c(0, 2), 'h', ans);
  assert.ok(logged.some((l) => l === 'live activity update answered 410 ExpiredToken'), logged.join(' | '));
});
