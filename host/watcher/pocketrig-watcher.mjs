#!/usr/bin/env node
// PocketRig watcher: runs next to the OpenRig daemon and posts to ntfy when a
// seat needs you, with actions you can take from the lock screen.
//
// Every notification has one shape: who and what in the title ("lead needs
// approval"), then role › rig › project › device, then the exact ask. Answer
// buttons come first and Open last. Tapping Allow once / Deny makes the phone
// POST (over Tailscale) to this watcher's /answer endpoint, which sends the
// key to the seat and publishes the result under the ask's ntfy sequence id,
// so the result replaces the notification. No dependencies; Node 22+.
//
// Configure with env vars (and ~/.config/pocketrig/watcher.json, which the
// app writes over SSH: {"hostName", "address", "kinds"}):
//   POCKETRIG_NTFY_TOPIC     required, e.g. pocketrig-k3v9q2m7x1
//   POCKETRIG_NTFY_SERVER    default https://ntfy.sh
//   POCKETRIG_NTFY_TOKEN     optional access token for a protected topic
//   POCKETRIG_HOST           device name shown in notifications (default: hostname)
//   POCKETRIG_ADDRESS        how the phone reaches this host (default: hostname)
//   POCKETRIG_ANSWER_PORT    default 7434; 0 turns the action buttons off
//   POCKETRIG_ANSWER_BIND    default 0.0.0.0 (requests need the token anyway)
//   POCKETRIG_ANSWER_TOKEN   default: a random token kept in ~/.config/pocketrig/answer-token
//   POCKETRIG_KINDS          default permission,question,blocked (also: rig)
//   OPENRIG_URL              default http://127.0.0.1:7433
//   POCKETRIG_POLL_MS        safety-net poll, default 8000
//   POCKETRIG_NOTIFY_EXISTING=1  also notify for seats already waiting at start
import { execFile } from 'node:child_process';
import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import { activityContent, isWorking, liveActivityDriver, pushSender, usageSummary } from './push.mjs';

export const ALL_KINDS = ['permission', 'question', 'blocked', 'rig'];
const DEFAULT_KINDS = ['permission', 'question', 'blocked'];

/** Same rule as the app's Seat.fromJson: any of the daemon's needs-input signals. */
export function needsInput(node) {
  const a = node.activityState;
  const count = a && a.needsInput && typeof a.needsInput.count === 'number' ? a.needsInput.count : 0;
  return node.arbitratedNeedsInput === true || node.needsAttention === true || count > 0 ||
    node.lifecycleState === 'attention_required';
}

export function needsReason(node) {
  const a = node.activityState;
  return (a && a.needsInput && a.needsInput.reason) || null;
}

/**
 * A Claude Code dialog (permission, question, trust) has numbered choices (`❯ 1. Yes`) or, without numbers, an
 * `Esc to cancel` footer. The same rule, in the same words, as the app's noDialogOnScreen in
 * lib/data/prompt_screen.dart; change both together.
 */
export const CHOICE_LINE = /^\s*(?:❯\s*)?[1-9]\.\s+\S|\bEsc to cancel\b/m;

/** Whether [screen], the visible text of a Claude pane, shows no dialog. An empty screen proves nothing. */
export function noDialogOnScreen(screen) {
  return screen.trim() !== '' && !CHOICE_LINE.test(screen);
}

/** The visible screen of tmux session [session], or null when it can't be read. */
export function readScreen(session) {
  return new Promise((resolve) =>
    execFile('tmux', ['capture-pane', '-p', '-t', `=${session}:`], { timeout: 3000 }, (e, out) => resolve(e ? null : out)));
}

/**
 * Whether [node] waits on a person. The daemon holds a Claude permission or question ask until the turn ends when
 * it never saw the dialog (a subagent's, answered by auto mode), so for those two reasons the screen has the last
 * word: no dialog on it, no ask. Anything unreadable, any other reason or runtime, keeps the daemon's answer.
 * Reads the screen only for such an ask.
 */
export async function asking(node, screen = readScreen) {
  if (!needsInput(node)) return false;
  const reason = needsReason(node);
  if (node.runtime !== 'claude-code' || !node.canonicalSessionName ||
      (reason !== 'permission_prompt' && reason !== 'selection_prompt')) return true;
  const text = await screen(node.canonicalSessionName).catch(() => null);
  return !(typeof text === 'string' && noDialogOnScreen(text));
}

/**
 * "Bash: npm test" → {tool:'Bash', detail:'npm test'}; free text → {detail}.
 * OpenRig sends codes instead: permission_prompt (a permission menu is up,
 * tool unknown), selection_prompt and idle_prompt.
 */
export function parseAsk(reason) {
  const r = (reason || '').trim();
  if (r === 'permission_prompt') return { tool: null, detail: 'Wants to use a tool. The command is in its terminal.', permission: true };
  if (r === 'selection_prompt') return { tool: null, detail: 'Asked you to pick an option' };
  if (r === 'idle_prompt') return { tool: null, detail: 'Waiting for your input' };
  const m = /^([A-Z][A-Za-z]+)(?:\(|:\s*)(.*?)\)?$/s.exec(r);
  if (m && m[2].trim()) return { tool: m[1], detail: m[2].trim() };
  return { tool: null, detail: r };
}

/** A tool call waiting for approval is a permission; anything else a question. */
export function seatKind(seat) {
  const ask = parseAsk(seat.reason);
  return ask.tool || ask.permission ? 'permission' : 'question';
}

/**
 * The folder most of a rig's seats run in, as its last path segment; a worktree counts as its main checkout, the way the app's
 * Projects tab names it (lib/models.dart `mainCheckout`).
 * shortcut: goes by the path like the app, so a worktree outside .claude/worktrees or .worktrees stays its own project.
 */
export function projectOf(nodes) {
  const counts = new Map();
  for (const n of nodes) if (n.cwd) counts.set(n.cwd, (counts.get(n.cwd) || 0) + 1);
  let best = null;
  for (const [cwd, c] of counts) if (!best || c > best[1]) best = [cwd, c];
  const root = best && best[0].replace(/^(.+?)\/(?:\.claude\/worktrees|\.worktrees)\/[^/]+(?:\/|$).*$/, '$1');
  return root ? root.split('/').filter(Boolean).pop() || root : null;
}

/** role › rig › project › device, skipping parts we don't know. */
export function contextPath(cfg, { project, rigName, role }) {
  return [role, rigName, project, cfg.hostName].filter(Boolean).join(' › ');
}

/**
 * Seats that went from not waiting to waiting. `prev` maps seat keys to the
 * last known state; it is updated in place. Seats that disappear are dropped,
 * so a restarted seat can notify again.
 */
export function newlyWaiting(prev, seats) {
  const out = [];
  const seen = new Set();
  for (const s of seats) {
    seen.add(s.key);
    const was = prev.get(s.key) === true;
    if (s.waiting && !was) out.push(s);
    prev.set(s.key, s.waiting);
  }
  for (const k of [...prev.keys()]) if (!seen.has(k)) prev.delete(k);
  return out;
}

/** Deep link the app opens: pocketrig://seat/<session>?host=<host>[&view=chat]. */
export function seatLink(session, host, view) {
  const q = new URLSearchParams();
  if (host) q.set('host', host);
  if (view) q.set('view', view);
  const qs = q.toString();
  return `pocketrig://seat/${encodeURIComponent(session)}${qs ? `?${qs}` : ''}`;
}

/**
 * The ntfy sequence id of one ask: answering publishes the result under the
 * same id, so ntfy replaces the notification instead of adding another.
 * Letters, digits, - and _ only; unique per ask (a seat asks again later).
 */
export function askSeq(kind, id, now = Date.now()) {
  const h = createHash('sha1').update(String(id)).digest('hex').slice(0, 12);
  return `pr-${kind}-${h}-${now.toString(36)}`;
}

/** A sequence id from a button's body, or null when it isn't one we made. */
export const validSeq = (seq) => (typeof seq === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(seq) ? seq : null);

/** Adds [seq] to a result message so it replaces the ask it answers. */
const replacing = (msg, seq) => (validSeq(seq) ? { ...msg, sequence_id: seq } : msg);

/** What a seat or agent outside a rig is being asked right now: a ticket is only good for this prompt. */
export const seatPrompt = (seat) => String(seat.reason || '');
export const loosePrompt = (a) => [a.tool, a.detail, a.message].map((v) => v || '').join('\n');

/**
 * The proof an answer button carries instead of the answer token: an HMAC of
 * this one answer to this one prompt. Anyone who can read the ntfy topic
 * sees it, but it can only give that answer, and only while that prompt is up.
 */
export function ticket(token, body, prompt = '') {
  const what = [body.session ?? null, body.loose ?? null, body.snooze ?? null, body.answer ?? null, body.minutes ?? null, prompt, body.seq ?? null];
  return createHmac('sha256', token).update(JSON.stringify(what)).digest('base64url');
}

/** Proof, carried in a started activity's attributes, that a token post is for that start. */
export const activityTicket = (token, id) => createHmac('sha256', token).update(JSON.stringify(['activity-token', id])).digest('base64url');

function ticketOk(token, body, prompt) {
  if (!token || typeof body.ticket !== 'string') return false;
  const a = Buffer.from(body.ticket), b = Buffer.from(ticket(token, body, prompt));
  return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * An answer button. It carries a [ticket] for this one answer to this one
 * prompt, not the answer token. `clear` stays off: the result replaces the
 * notification (same sequence id), and when the phone can't reach this
 * watcher the ask stays up, so it isn't lost.
 */
function answerAction(cfg, label, body, prompt = '') {
  return {
    action: 'http',
    label,
    url: `${cfg.answerBase}/answer`,
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...body, ticket: ticket(cfg.answerToken, body, prompt) }),
    clear: false,
  };
}

/** The last button of every ask: open it in the app. */
const openAction = (url, label = 'Open') => ({ action: 'view', label, url, clear: true });

/** Why an answer didn't land, as what to do about it. */
export function answerFix(reason) {
  switch (reason) {
    case 'not_waiting': return 'Already answered, nothing to do.';
    case 'not_in_tmux': return 'It isn\'t in tmux. Answer it at the Mac, or Restart in tmux from the app.';
    default: return reason ? `${reason} Open it in PocketRig to answer.` : 'Open it in PocketRig to answer.';
  }
}

/**
 * The ntfy JSON message for a seat that needs you. Title says who and what,
 * the first body line says where (role › rig › project › device), the second
 * what it wants. ntfy shows at most three actions.
 */
export function seatMessage(cfg, seat, seq = askSeq('seat', seat.session)) {
  const kind = seatKind(seat);
  const ask = parseAsk(seat.reason);
  const where = contextPath(cfg, { project: seat.project, rigName: seat.rigName, role: seat.logicalId });
  const open = openAction(seatLink(seat.session, cfg.hostName));
  const canAnswer = Boolean(cfg.answerBase && cfg.answerToken);
  if (kind === 'permission') {
    return {
      topic: cfg.topic,
      sequence_id: seq,
      title: `${seat.logicalId} needs approval`,
      message: `${where}\n${ask.tool ? `${ask.tool} · ` : ''}${ask.detail}`,
      priority: 4,
      tags: ['raising_hand'],
      click: seatLink(seat.session, cfg.hostName),
      actions: canAnswer
        ? [
            answerAction(cfg, 'Allow once', { session: seat.session, answer: 'allow', seq }, seatPrompt(seat)),
            answerAction(cfg, 'Deny', { session: seat.session, answer: 'deny', seq }, seatPrompt(seat)),
            open,
          ]
        : [open],
    };
  }
  return {
    topic: cfg.topic,
    sequence_id: seq,
    title: `${seat.logicalId} asked a question`,
    message: `${where}\n${ask.detail || 'Waiting for your answer'}`,
    priority: 4,
    tags: ['speech_balloon'],
    click: seatLink(seat.session, cfg.hostName, 'chat'),
    actions: [
      { action: 'view', label: 'Reply…', url: seatLink(seat.session, cfg.hostName, 'chat'), clear: true },
      open,
    ],
  };
}

const PERSON = /^human(-[A-Za-z0-9._-]+)?@(kernel|host)$/;

/**
 * The seat behind an attention item. Items blocked on the person name only
 * the person (`recipient`), so the seat comes from the queue row it links
 * to: the owner of the work, or the sender of an update. `get(path)` reads
 * the daemon.
 */
export async function attentionAsker(item, get) {
  if (item.asker || typeof item.source !== 'string' || !item.source.startsWith('/api/queue/')) return item.asker || null;
  try {
    const q = await get(item.source);
    return [q?.waiting?.owner, q?.destinationSession, q?.sourceSession].find((s) => typeof s === 'string' && !PERSON.test(s)) || null;
  } catch {
    return null;
  }
}

/** An open item from /api/attention: a question or work blocked on you. */
export function attentionMessage(cfg, item, seq = askSeq('item', item.id)) {
  const asker = item.asker || '';
  const [role, rigName] = asker.includes('@') ? asker.split('@') : [asker || null, null];
  const project = item.project && item.project.root ? item.project.root.split('/').filter(Boolean).pop() : null;
  const where = contextPath(cfg, { project, rigName, role });
  const blocked = !item.answer || item.answer.verb === 'resolve';
  const actions = [];
  // A question is answered in the chat: Reply… first. Blocked work is opened, then maybe snoozed.
  if (asker && !blocked) actions.push({ action: 'view', label: 'Reply…', url: seatLink(asker, cfg.hostName, 'chat'), clear: true });
  if (asker && blocked) actions.push(openAction(seatLink(asker, cfg.hostName)));
  if (cfg.answerBase && cfg.answerToken) {
    actions.push(answerAction(cfg, 'Snooze 1 h', { snooze: item.id, minutes: 60, seq }));
  }
  if (asker && !blocked) actions.push(openAction(seatLink(asker, cfg.hostName)));
  return {
    topic: cfg.topic,
    sequence_id: seq,
    title: blocked ? `${role || 'A seat'} is blocked on you` : `${role || 'A seat'} asked a question`,
    message: `${where}\n${item.summary || 'Open PocketRig'}`,
    priority: blocked ? 3 : 4,
    tags: [blocked ? 'construction' : 'speech_balloon'],
    ...(asker ? { click: seatLink(asker, cfg.hostName, blocked ? null : 'chat') } : {}),
    actions,
  };
}

/** A rig that was running and is now stopped. */
export function rigStoppedMessage(cfg, rig, project) {
  return {
    topic: cfg.topic,
    title: `${rig.name} stopped${rig.latestSnapshot ? ` · snapshot ${rig.latestSnapshot}` : ''}`,
    message: `${contextPath(cfg, { project, rigName: rig.name })}\n${rig.latestSnapshot ? `Last snapshot ${rig.latestSnapshot}.` : 'No snapshot.'}`,
    priority: 3,
    tags: ['warning'],
  };
}

/** The follow-up after a button was used, so you see that it worked. */
/**
 * The follow-up after a button was used, so you see that it worked. With the
 * ask's [seq] it replaces that notification. A failure says what to do.
 */
export function resultMessage(cfg, seat, answer, ok, error, seq) {
  const where = contextPath(cfg, { project: seat.project, rigName: seat.rigName, role: seat.logicalId });
  const ask = parseAsk(seat.reason);
  if (!ok) {
    return replacing({ topic: cfg.topic, title: `Couldn't answer ${seat.logicalId}`, message: `${error}\n${where}`, priority: 4, tags: ['x'],
      click: seatLink(seat.session, cfg.hostName), actions: [openAction(seatLink(seat.session, cfg.hostName))] }, seq);
  }
  return replacing(answer === 'allow'
    ? { topic: cfg.topic, title: `✓ Allowed once · ${seat.logicalId}`, message: `${where}\nRunning ${ask.detail || 'the request'}`, priority: 2, tags: ['white_check_mark'] }
    : { topic: cfg.topic, title: `✕ Denied · ${seat.logicalId}`, message: `${where}\n${seat.logicalId} is waiting for instructions`, priority: 2, tags: ['no_entry'],
        click: seatLink(seat.session, cfg.hostName, 'chat') }, seq);
}

/** Snoozing replaces the ask with when it comes back. */
export function snoozedMessage(cfg, minutes, seq) {
  const span = minutes % 60 === 0 ? `${minutes / 60} h` : `${minutes} min`;
  return replacing({ topic: cfg.topic, title: `Snoozed for ${span}`, message: 'It comes back if it is still open then.', priority: 1, tags: ['zzz'] }, seq);
}

/** Splits an SSE byte stream into `data:` payloads (no event names used). */
export function* sseFrames(buffer) {
  let rest = buffer;
  let idx;
  while ((idx = rest.search(/\r?\n\r?\n/)) >= 0) {
    const frame = rest.slice(0, idx);
    rest = rest.slice(idx + (rest[idx] === '\r' ? 4 : 2));
    const data = frame.split(/\r?\n/).filter((l) => l.startsWith('data:')).map((l) => l.slice(5).replace(/^ /, '')).join('\n');
    if (data) yield { data };
  }
  return rest;
}

/** Constant-time check of an `Authorization: Bearer …` header. */
export function tokenOk(header, token) {
  if (!token || typeof header !== 'string' || !header.startsWith('Bearer ')) return false;
  const a = Buffer.from(header.slice(7)), b = Buffer.from(token);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** POST /activity-token?start=<id> {token, ticket}: the phone reports a push-started activity's token with no app and no SSH. */
async function activityTokenRoute(deps, req, reply) {
  let body = '';
  for await (const c of req) { body += c; if (body.length > 4096) return reply(413, { error: 'too_large' }); }
  let msg;
  try { msg = JSON.parse(body); } catch { return reply(400, { error: 'invalid_json' }); }
  const id = new URL(req.url, 'http://x').searchParams.get('start') || '';
  const want = deps.token && id ? Buffer.from(activityTicket(deps.token, id)) : null;
  const got = Buffer.from(typeof msg?.ticket === 'string' ? msg.ticket : '');
  if (!want || got.length !== want.length || !timingSafeEqual(got, want)) return reply(401, { error: 'unauthorized' });
  if (typeof msg.token !== 'string' || !/^[0-9a-f]{16,512}$/i.test(msg.token)) return reply(400, { error: 'token required' });
  if (!deps.activityToken?.(id, msg.token)) return reply(404, { error: 'unknown_start' });
  return reply(200, { ok: true });
}

/**
 * The /answer endpoint. `deps.findSeat(session)` returns the seat's current
 * state (or null), `deps.sendKeys(session, answer)` delivers it, and
 * `deps.snooze(id, minutes)` holds an attention item back.
 */
export function answerHandler(deps) {
  const spent = new Set(); // tickets already used
  return async (req, res) => {
    const reply = (status, body) => { if (res.headersSent) return; res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
    const route = req.method === 'POST' ? req.url.split('?')[0] : null;
    if (route === '/activity-token') return activityTokenRoute(deps, req, reply);
    if (route !== '/answer' && route !== '/hook') return reply(404, { error: 'not_found' });
    // The hook and the app send the token; notification buttons send a ticket in the body instead.
    const bearer = tokenOk(req.headers.authorization, deps.token);
    if (!bearer && route === '/hook') return reply(401, { error: 'unauthorized' });
    let body = '';
    const limit = route === '/hook' ? 65536 : 4096;
    for await (const c of req) { body += c; if (body.length > limit) return reply(413, { error: 'too_large' }); }
    let msg;
    try { msg = JSON.parse(body); } catch { return reply(400, { error: 'invalid_json' }); }
    if (!msg || typeof msg !== 'object') return reply(400, { error: 'invalid_json' });
    if (!bearer && typeof msg.ticket !== 'string') return reply(401, { error: 'unauthorized' });
    // A ticket for a prompt that isn't up any more: the seat moved on to another one.
    const moved = (prompt) => !bearer && !ticketOk(deps.token, msg, prompt);
    if (route === '/hook') {
      if (!deps.hook) return reply(404, { error: 'not_found' });
      await deps.hook(msg, { pane: req.headers['x-tmux-pane'] || null, tmux: req.headers['x-tmux-session'] || null });
      return reply(200, { ok: true });
    }
    // A ticket answers once: native re-posts it on a timeout, and it must not approve a later identical prompt.
    const spend = () => {
      if (bearer) return true;
      if (spent.has(msg.ticket)) return false;
      spent.add(msg.ticket);
      if (spent.size > 500) spent.delete(spent.values().next().value);
      return true;
    };
    // Only used once the ticket checks out (or the app's bearer token): a forged body must not replace notifications.
    const seq = validSeq(msg.seq);
    if (typeof msg.loose === 'string' && deps.loose) {
      if (!['allow', 'deny'].includes(msg.answer)) return reply(400, { error: 'answer (allow|deny) required' });
      const a = deps.loose.get(msg.loose);
      if (!a) return reply(404, { error: 'agent_not_found' });
      if (!a.waiting || !a.pane) {
        // Not checked against a prompt (there is none now), so no sequence id: it can't replace a notification.
        reply(409, { error: 'not_waiting' });
        await deps.notify?.(looseResultMessage(deps.cfg, a, msg.answer, false, answerFix(a.pane ? 'not_waiting' : 'not_in_tmux'), bearer ? seq : null));
        return;
      }
      if (moved(loosePrompt(a))) {
        reply(409, { error: 'prompt_changed' });
        await deps.notify?.(looseResultMessage(deps.cfg, a, msg.answer, false, 'It is asking something else now. Open PocketRig to answer it.'));
        return;
      }
      if (!spend()) return reply(409, { error: 'already_answered' });
      try {
        await deps.sendPaneKeys(a.pane, msg.answer);
        a.waiting = false;
        deps.looseChanged?.();
        reply(200, { ok: true });
        await deps.notify?.(looseResultMessage(deps.cfg, a, msg.answer, true, null, seq));
        return;
      } catch (e) {
        reply(502, { error: 'send_failed', message: e.message });
        spent.delete(msg.ticket); // nothing was pressed: the retry may go through
        await deps.notify?.(looseResultMessage(deps.cfg, a, msg.answer, false, answerFix(`Couldn't reach it: ${e.message}.`), seq));
        return;
      }
    }
    if (msg.snooze) {
      if (moved('')) return reply(401, { error: 'unauthorized' });
      const minutes = Math.min(Math.max(Number(msg.minutes) || 60, 1), 24 * 60);
      deps.snooze(String(msg.snooze), minutes);
      reply(200, { ok: true, snoozed: msg.snooze });
      if (seq) await deps.notify?.(snoozedMessage(deps.cfg, minutes, seq));
      return;
    }
    if (typeof msg.session !== 'string' || !['allow', 'deny'].includes(msg.answer)) return reply(400, { error: 'session and answer (allow|deny) required' });
    const seat = await deps.findSeat(msg.session);
    if (!seat) return reply(404, { error: 'seat_not_found' });
    // A stale button must not press keys into a seat that moved on.
    if (!seat.waiting) {
      // Not checked against a prompt (there is none now), so no sequence id: it can't replace a notification.
      reply(409, { error: 'not_waiting' });
      await deps.notify?.(resultMessage(deps.cfg, seat, msg.answer, false, answerFix('not_waiting'), bearer ? seq : null));
      return;
    }
    // Waiting, but on a different prompt than the button was for: never answer that one blind.
    if (moved(seatPrompt(seat))) {
      reply(409, { error: 'prompt_changed' });
      await deps.notify?.(resultMessage(deps.cfg, seat, msg.answer, false, 'It is asking something else now. Open PocketRig to answer it.'));
      return;
    }
    if (!spend()) return reply(409, { error: 'already_answered' });
    try {
      await deps.sendKeys(msg.session, msg.answer);
      reply(200, { ok: true });
      await deps.notify?.(resultMessage(deps.cfg, seat, msg.answer, true, null, seq));
      return;
    } catch (e) {
      reply(502, { error: 'send_failed', message: e.message });
      spent.delete(msg.ticket);
      await deps.notify?.(resultMessage(deps.cfg, seat, msg.answer, false, answerFix(`Couldn't reach the seat: ${e.message}.`), seq));
      return;
    }
  };
}

/** Allow once = "1" (Claude Code's first option); Deny = Escape. */
export async function sendSeatKeys(daemon, session, answer) {
  const payload = answer === 'allow' ? { type: 'text', text: '1' } : { type: 'keys', keys: ['Escape'] };
  try {
    await new Promise((resolve, reject) => {
      const ws = new WebSocket(`${daemon.replace(/^http/, 'ws')}/api/terminal/${encodeURIComponent(session)}`);
      const t = setTimeout(() => { ws.close(); reject(new Error('timeout')); }, 4000);
      ws.onopen = () => { ws.send(JSON.stringify(payload)); setTimeout(() => { clearTimeout(t); ws.close(); resolve(); }, 300); };
      ws.onerror = () => { clearTimeout(t); reject(new Error('daemon terminal unavailable')); };
    });
  } catch {
    // The daemon only serves the terminal socket with its web UI on: tmux it is.
    await new Promise((resolve, reject) =>
      // `=name` matches exactly (a bare name prefix-matches another rig's seat); has-session fails loudly first.
      execFile('tmux', ['has-session', '-t', `=${session}`], (e) => {
        if (e) return reject(new Error(`no tmux session ${session}`));
        execFile('tmux', ['send-keys', '-t', `=${session}:`, answer === 'allow' ? '1' : 'Escape'], (e2) => (e2 ? reject(e2) : resolve()));
      }));
  }
}

// ---------------------------------------------------------------------------
// Agents outside a rig. A Claude Code hook (claude-hook.sh) posts every
// Notification / PostToolUse / UserPromptSubmit / Stop / SessionEnd event to
// /hook, with the tmux pane it runs in when there is one. Sessions that are
// rig seats are left to the daemon.

/** The hook events we listen to, and what each means for "waiting". */
export const HOOK_EVENTS = ['SessionStart', 'Notification', 'PreToolUse', 'PostToolUse', 'UserPromptSubmit', 'Stop', 'SessionEnd'];

/**
 * Applies one hook event to the registry (a Map of session id → agent).
 * Returns the agent when it just started waiting on a permission prompt,
 * so the caller can notify; null otherwise.
 */
export function applyHook(registry, ev, where = {}, now = Date.now()) {
  const id = typeof ev.session_id === 'string' ? ev.session_id : null;
  if (!id) return null;
  if (ev.hook_event_name === 'SessionEnd') { registry.delete(id); return null; }
  const prev = registry.get(id);
  const a = prev || { id, firstSeen: now };
  a.cwd = ev.cwd || a.cwd || null;
  a.transcriptPath = ev.transcript_path || a.transcriptPath || null;
  if (where.pane) a.pane = where.pane;
  if (where.tmux) a.tmux = where.tmux;
  a.at = now;
  registry.set(id, a);
  if (ev.hook_event_name === 'Notification') {
    const message = typeof ev.message === 'string' ? ev.message : '';
    // The idle reminder fires a while after Stop: it asks nothing.
    if (/waiting for your input/i.test(message)) {
      a.waiting = false;
      a.kind = null;
      a.message = null;
      a.activity = 'idle';
      return null;
    }
    const permission = /permission/i.test(message);
    const was = a.waiting && a.kind === 'permission';
    a.waiting = true;
    a.kind = permission ? 'permission' : 'idle';
    a.message = message;
    return permission && !was ? a : null;
  }
  a.activity = ev.hook_event_name === 'Stop' || ev.hook_event_name === 'SessionStart' ? 'idle' : 'working';
  a.activeAt = now;
  // Fires before a permission prompt, so it can't answer one.
  if (ev.hook_event_name === 'PreToolUse') return null;
  a.waiting = false;
  a.kind = null;
  a.message = null;
  a.detail = null;
  return null;
}

/** Drops agents not heard from in [maxAgeMs] that aren't waiting. */
export function pruneLoose(registry, now = Date.now(), maxAgeMs = 24 * 3600e3) {
  for (const [id, a] of registry) if (!a.waiting && now - a.at > maxAgeMs) registry.delete(id);
}

/** The name an agent outside a rig goes by: its tmux session, else "claude". */
export const looseName = (a) => a.tmux || 'claude';
const lastDir = (p) => (p ? p.split('/').filter(Boolean).pop() || p : null);

/** pocketrig://agent/<session id>?host=&tmux=&cwd= */
export function agentLink(a, host) {
  const q = new URLSearchParams();
  if (host) q.set('host', host);
  if (a.tmux) q.set('tmux', a.tmux);
  if (a.cwd) q.set('cwd', a.cwd);
  return `pocketrig://agent/${encodeURIComponent(a.id)}?${q}`;
}

/**
 * A hook names the transcript to read; only Claude Code's own logs (`.jsonl`
 * under one of [roots], symlinks resolved) are read, so a forged hook can't
 * publish another file's contents.
 */
export function transcriptAllowed(p, roots) {
  try {
    const real = fs.realpathSync(p);
    return real.endsWith('.jsonl') && roots.some((r) => {
      const root = fs.realpathSync(r);
      return real.startsWith(root + path.sep);
    });
  } catch {
    return false;
  }
}

/** The tool call an agent is asking about, from the end of its transcript. */
export function lastToolUse(jsonlTail) {
  const lines = jsonlTail.split('\n').reverse();
  for (const line of lines) {
    if (!line.includes('"tool_use"')) continue;
    try {
      const j = JSON.parse(line);
      const blocks = j.message && Array.isArray(j.message.content) ? j.message.content : [];
      const t = blocks.filter((b) => b && b.type === 'tool_use').pop();
      if (!t) continue;
      const i = t.input || {};
      const detail = i.command || i.file_path || i.path || i.url || i.pattern || i.description || '';
      return { tool: t.name, detail: String(detail).split('\n')[0].slice(0, 160) };
    } catch { /* partial line */ }
  }
  return null;
}

/** The ntfy message for an agent outside a rig that wants permission. */
export function looseMessage(cfg, a, seq = askSeq('agent', a.id)) {
  const name = looseName(a);
  const where = contextPath(cfg, { project: lastDir(a.cwd), rigName: 'no rig', role: name });
  const what = a.detail ? `${a.tool} · ${a.detail}` : (a.message || 'Waiting for your approval');
  const open = openAction(agentLink(a, cfg.hostName), a.tmux ? 'Open' : 'Open chat');
  const canAnswer = Boolean(a.pane && cfg.answerBase && cfg.answerToken);
  return {
    topic: cfg.topic,
    sequence_id: seq,
    title: `${name} needs approval`,
    message: `${where}\n${what}${a.pane ? '' : '. Not in tmux, so answer it at the Mac.'}`,
    priority: 4,
    tags: ['raising_hand'],
    click: agentLink(a, cfg.hostName),
    actions: canAnswer
      ? [answerAction(cfg, 'Allow once', { loose: a.id, answer: 'allow', seq }, loosePrompt(a)),
          answerAction(cfg, 'Deny', { loose: a.id, answer: 'deny', seq }, loosePrompt(a)), open]
      : [open],
  };
}

export function looseResultMessage(cfg, a, answer, ok, error, seq) {
  const name = looseName(a);
  const where = contextPath(cfg, { project: lastDir(a.cwd), rigName: 'no rig', role: name });
  if (!ok) {
    return replacing({ topic: cfg.topic, title: `Couldn't answer ${name}`, message: `${error}\n${where}`, priority: 4, tags: ['x'],
      click: agentLink(a, cfg.hostName), actions: [openAction(agentLink(a, cfg.hostName))] }, seq);
  }
  return replacing(answer === 'allow'
    ? { topic: cfg.topic, title: `✓ Allowed once · ${name}`, message: `${where}\nRunning ${a.detail || 'the request'}`, priority: 2, tags: ['white_check_mark'] }
    : { topic: cfg.topic, title: `✕ Denied · ${name}`, message: `${where}\n${name} is waiting for instructions`, priority: 2, tags: ['no_entry'], click: agentLink(a, cfg.hostName) }, seq);
}

/** tmux send-keys to a pane id (%12). */
export function sendPaneKeys(pane, answer) {
  if (!/^%\d+$/.test(pane)) return Promise.reject(new Error('bad pane'));
  return new Promise((resolve, reject) =>
    execFile('tmux', ['send-keys', '-t', pane, answer === 'allow' ? '1' : 'Escape'], (e) => (e ? reject(e) : resolve())));
}

/** PocketRig's own hook script, from a checkout or from the app's install. */
const OUR_HOOK = /\/(host\/watcher|\.config\/pocketrig)\/claude-hook\.sh$/;

/**
 * Adds [command] as a hook for HOOK_EVENTS to a Claude Code settings object,
 * once. A PocketRig hook at another path (a checkout, an older install) is
 * replaced so events don't fire twice. Returns true when something changed.
 */
export function addClaudeHooks(settings, command) {
  let changed = false;
  settings.hooks = settings.hooks && typeof settings.hooks === 'object' ? settings.hooks : {};
  const stale = (h) => h.command !== command && OUR_HOOK.test(h.command || '');
  for (const ev of HOOK_EVENTS) {
    let list = Array.isArray(settings.hooks[ev]) ? settings.hooks[ev] : [];
    list = list.flatMap((m) => {
      if (!Array.isArray(m.hooks) || !m.hooks.some(stale)) return [m];
      changed = true;
      const hooks = m.hooks.filter((h) => !stale(h));
      return hooks.length ? [{ ...m, hooks }] : [];
    });
    const has = list.some((m) => Array.isArray(m.hooks) && m.hooks.some((h) => h.command === command));
    if (!has) { list.push({ matcher: '', hooks: [{ type: 'command', command }] }); changed = true; }
    settings.hooks[ev] = list;
  }
  return changed;
}

/** Writes the hooks into ~/.claude/settings.json (keeps everything else). */
export function installClaudeHooks(command, file = path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'), 'settings.json')) {
  let settings = {};
  try { settings = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  if (!addClaudeHooks(settings, command)) return false;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (fs.existsSync(file)) fs.copyFileSync(file, `${file}.pocketrig-backup`);
  fs.writeFileSync(file, `${JSON.stringify(settings, null, 2)}\n`);
  return true;
}

const configDir = () => path.join(os.homedir(), '.config', 'pocketrig');

/** The answer token: env, else a random one kept (mode 600) next to the config. */
export function loadAnswerToken(env = process.env, dir = configDir()) {
  if (env.POCKETRIG_ANSWER_TOKEN) return env.POCKETRIG_ANSWER_TOKEN;
  const file = path.join(dir, 'answer-token');
  try { return fs.readFileSync(file, 'utf8').trim(); } catch { /* make one */ }
  const token = randomBytes(24).toString('base64url');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(file, token, { mode: 0o600 });
  return token;
}

/** Env settings, overlaid with the app-written watcher.json when present. */
export function config(env = process.env, dir = configDir()) {
  const topic = env.POCKETRIG_NTFY_TOPIC;
  if (!topic || !/^[A-Za-z0-9_-]{1,64}$/.test(topic)) {
    throw new Error('Set POCKETRIG_NTFY_TOPIC to the topic shown in the app (letters, digits, - and _).');
  }
  let file = {};
  try { file = JSON.parse(fs.readFileSync(path.join(dir, 'watcher.json'), 'utf8')); } catch { /* none yet */ }
  const port = Number(env.POCKETRIG_ANSWER_PORT ?? 7434);
  const address = (typeof file.address === 'string' && file.address) || env.POCKETRIG_ADDRESS || os.hostname();
  const kinds = Array.isArray(file.kinds) ? file.kinds.filter((k) => ALL_KINDS.includes(k))
    : (env.POCKETRIG_KINDS ? env.POCKETRIG_KINDS.split(',').map((s) => s.trim()) : DEFAULT_KINDS);
  return {
    topic,
    dir,
    devices: Array.isArray(file.devices) ? file.devices.filter((d) => d && typeof d.token === 'string' && ['ios', 'android'].includes(d.platform)) : [],
    server: (env.POCKETRIG_NTFY_SERVER || 'https://ntfy.sh').replace(/\/+$/, ''),
    token: env.POCKETRIG_NTFY_TOKEN || null,
    hostName: (typeof file.hostName === 'string' && file.hostName) || env.POCKETRIG_HOST || os.hostname(),
    daemon: (env.OPENRIG_URL || 'http://127.0.0.1:7433').replace(/\/+$/, ''),
    pollMs: Number(env.POCKETRIG_POLL_MS || 8000),
    notifyExisting: env.POCKETRIG_NOTIFY_EXISTING === '1',
    kinds: new Set(kinds),
    answerPort: port,
    answerBind: env.POCKETRIG_ANSWER_BIND || '0.0.0.0',
    answerBase: port > 0 ? (env.POCKETRIG_ANSWER_URL || `http://${address}:${port}`) : null,
    answerToken: port > 0 ? loadAnswerToken(env, dir) : null,
  };
}

const log = (...a) => console.log(new Date().toISOString(), ...a);

async function getJson(url) {
  const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
  if (!res.ok) throw new Error(`${url} → ${res.status}`);
  return res.json();
}

/** Waits between publish attempts; the third failure gives up. */
export const PUBLISH_RETRY_MS = [2000, 6000];

/**
 * Publish one ntfy JSON message (POST to the server root). A failed connection
 * is retried: on some hosts the connection to ntfy times out now and then, and
 * a dropped post is a permission request nobody hears about.
 */
const senders = new Map(); // config dir → push sender (keeps the FCM token between sends)

export async function publish(cfg, msg, { fetchImpl = fetch, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) } = {}) {
  // Native push goes out first and on its own; ntfy stays until push is verified on a device.
  if (cfg.devices?.length) {
    if (!senders.has(cfg.dir)) senders.set(cfg.dir, pushSender(cfg.dir, { log, fetchImpl }));
    senders.get(cfg.dir)(cfg.devices, msg).catch((e) => log('push failed:', e.message)); // not awaited: a slow APNs must not hold up ntfy or /answer
  }
  const headers = { 'content-type': 'application/json' };
  if (cfg.token) headers.authorization = `Bearer ${cfg.token}`;
  for (let attempt = 0; ; attempt++) {
    try {
      const res = await fetchImpl(cfg.server, { method: 'POST', headers, body: JSON.stringify(msg), signal: AbortSignal.timeout(10000) });
      if (!res.ok) log('ntfy refused:', res.status, await res.text().catch(() => ''));
      else if (attempt > 0) log(`ntfy posted after ${attempt} retr${attempt === 1 ? 'y' : 'ies'}`);
      return res.ok;
    } catch (e) {
      const cause = e.cause && (e.cause.code || e.cause.message);
      if (attempt >= PUBLISH_RETRY_MS.length) {
        log('ntfy unreachable:', e.message, cause ? `(${cause})` : '', `after ${attempt + 1} tries`);
        return false;
      }
      await sleep(PUBLISH_RETRY_MS[attempt]);
    }
  }
}

export async function main(env = process.env, opts = {}) {
  const dir = opts.configDir || configDir();
  let cfg = config(env, dir);
  const sendKeys = opts.sendKeys || ((session, answer) => sendSeatKeys(cfg.daemon, session, answer));
  const driver = liveActivityDriver(dir, { log });
  const seatState = new Map();
  const rigState = new Map();
  const seenAttention = new Set();
  const snoozed = new Map(); // attention id → until (ms)
  const lastSeats = new Map(); // session → seat (for /answer)
  const lastProject = new Map(); // rigId → project, for rigs that stopped
  const loose = new Map(); // Claude session id → agent outside a rig
  const looseFile = path.join(dir, 'loose.json');
  const sendKeysToPane = opts.sendPaneKeys || sendPaneKeys;
  const transcriptRoots = opts.transcriptRoots || [path.join(os.homedir(), '.claude')];
  function saveLoose() {
    pruneLoose(loose);
    try {
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(looseFile, JSON.stringify([...loose.values()]));
    } catch (e) { log('could not write loose.json:', e.message); }
  }
  async function onHook(ev, where) {
    // A rig seat's own hooks: the daemon already reports those.
    if (where.tmux && lastSeats.has(where.tmux)) return;
    const a = applyHook(loose, ev, where);
    if (a) {
      if (a.transcriptPath && transcriptAllowed(a.transcriptPath, transcriptRoots)) {
        try {
          delete a.tool;
          delete a.detail;
          const fd = fs.openSync(a.transcriptPath, 'r');
          const size = fs.fstatSync(fd).size;
          const len = Math.min(size, 262144);
          const buf = Buffer.alloc(len);
          fs.readSync(fd, buf, 0, len, size - len);
          fs.closeSync(fd);
          Object.assign(a, lastToolUse(buf.toString('utf8')) || {});
        } catch { /* no detail then */ }
      }
      if (cfg.kinds.has('permission')) {
        log('agent outside a rig waiting:', looseName(a), a.cwd || '');
        await publish(cfg, looseMessage(cfg, a));
      }
    }
    saveLoose();
  }
  let seeded = cfg.notifyExisting;
  let running = false;
  let again = false;

  async function readSeats() {
    const rigs = await getJson(`${cfg.daemon}/api/ps`);
    const seats = [];
    const live = [];
    for (const rig of Array.isArray(rigs) ? rigs : []) {
      let nodes = [];
      if (rig.status !== 'stopped') {
        try {
          const raw = await getJson(`${cfg.daemon}/api/rigs/${encodeURIComponent(rig.rigId)}/nodes`);
          nodes = Array.isArray(raw) ? raw : (raw.nodes || []);
        } catch { /* skip this rig */ }
      }
      const project = projectOf(nodes);
      live.push({ rig, project });
      for (const n of nodes) {
        if (!n.canonicalSessionName) continue;
        seats.push({
          key: `${rig.rigId}/${n.logicalId}`,
          rigName: rig.name || rig.rigName || rig.rigId,
          project,
          logicalId: n.logicalId,
          session: n.canonicalSessionName,
          agent: n.nodeKind === 'agent' && n.runtime !== 'terminal',
          working: isWorking(n),
          waiting: await asking(n),
          reason: needsReason(n),
        });
      }
    }
    return { seats, live };
  }

  const usage = { at: 0, value: [] };
  /** Provider usage for the Live Activity: read at most once a minute, and a failed read keeps the last one. */
  async function readUsage() {
    if (Date.now() - usage.at < 60000) return usage.value;
    usage.at = Date.now();
    try { usage.value = usageSummary((await getJson(`${cfg.daemon}/api/provider/status`)).hostUsage); } catch { /* keep the last */ }
    return usage.value;
  }

  async function check() {
    if (running) { again = true; return; }
    running = true;
    try {
      cfg = config(env, dir); // pick up kinds / names the app wrote
      const { seats, live } = await readSeats();
      if (cfg.devices.some((d) => d.activityStartToken)) {
        driver(cfg.devices, activityContent(seats, Date.now(), await readUsage()), cfg.hostName, cfg.answerBase && cfg.answerToken ? { url: `${cfg.answerBase}/activity-token`, sign: (id) => activityTicket(cfg.answerToken, id) } : null).catch((e) => log('live activity failed:', e.message));
      }
      lastSeats.clear();
      for (const s of seats) lastSeats.set(s.session, s);
      for (const s of newlyWaiting(seatState, seats)) {
        if (!seeded || !cfg.kinds.has(seatKind(s))) continue;
        log('waiting:', s.session, s.reason || '');
        await publish(cfg, seatMessage(cfg, s));
      }
      for (const { rig, project } of live) {
        const was = rigState.get(rig.rigId);
        rigState.set(rig.rigId, rig.status);
        if (seeded && was && was !== 'stopped' && rig.status === 'stopped' && cfg.kinds.has('rig')) {
          await publish(cfg, rigStoppedMessage(cfg, rig, project || lastProject.get(rig.rigId)));
        }
        if (project) lastProject.set(rig.rigId, project);
      }
      try {
        const att = await getJson(`${cfg.daemon}/api/attention`);
        const now = Date.now();
        for (const item of (att.items || []).filter((i) => i.kind === 'action')) {
          const until = snoozed.get(item.id);
          const due = until !== undefined && until <= now;
          if (seenAttention.has(item.id) && !due) continue;
          seenAttention.add(item.id);
          snoozed.delete(item.id);
          const blocked = !item.answer || item.answer.verb === 'resolve';
          if (seeded && cfg.kinds.has(blocked ? 'blocked' : 'question')) {
            const asker = await attentionAsker(item, (p) => getJson(`${cfg.daemon}${p}`));
            await publish(cfg, attentionMessage(cfg, { ...item, asker }));
          }
        }
      } catch { /* attention feed is optional */ }
      seeded = true;
    } catch (e) {
      log('daemon check failed:', e.message);
    } finally {
      running = false;
      if (again) { again = false; setTimeout(check, 250); }
    }
  }

  let soon = null;
  const schedule = () => { if (!soon) soon = setTimeout(() => { soon = null; check(); }, 300); };

  // The global stream carries seat.activity_changed (rig streams don't), so
  // any event is a cue to re-check. replay=0: only new events.
  const stopped = new AbortController();
  async function listen() {
    while (!stopped.signal.aborted) {
      try {
        const res = await fetch(`${cfg.daemon}/api/events?replay=0`, { headers: { accept: 'text/event-stream' }, signal: stopped.signal });
        if (!res.ok) throw new Error(`events → ${res.status}`);
        log('listening to', `${cfg.daemon}/api/events`);
        const dec = new TextDecoder();
        let buf = '';
        for await (const chunk of res.body) {
          buf += dec.decode(chunk, { stream: true });
          const it = sseFrames(buf);
          let r;
          while (!(r = it.next()).done) {
            try {
              const ev = JSON.parse(r.value.data);
              if (/^(seat|agent|node|session|queue|rig|restore)\./.test(ev.type || '')) schedule();
            } catch { /* not JSON */ }
          }
          buf = r.value;
        }
        log('event stream ended; reconnecting');
      } catch (e) {
        if (stopped.signal.aborted) return;
        log('event stream error:', e.message);
      }
      await new Promise((r) => setTimeout(r, 5000).unref?.());
    }
  }

  let server = null;
  if (cfg.answerPort > 0) {
    server = http.createServer(answerHandler({
      get cfg() { return cfg; },
      token: cfg.answerToken,
      async findSeat(session) {
        try {
          const { seats } = await readSeats();
          return seats.find((s) => s.session === session) || null;
        } catch {
          return lastSeats.get(session) || null;
        }
      },
      sendKeys,
      hook: onHook,
      loose,
      sendPaneKeys: sendKeysToPane,
      looseChanged: saveLoose,
      snooze(id, minutes) { snoozed.set(id, Date.now() + minutes * 60000); log('snoozed', id, `${minutes}m`); },
      notify: (msg) => publish(cfg, msg),
      activityToken(id, token) { const ok = driver.report(id, token); if (ok) { log('live activity token reported'); schedule(); } return ok; },
    }));
    await new Promise((resolve) => server.listen(cfg.answerPort, cfg.answerBind, resolve));
    log(`answers on ${cfg.answerBind}:${server.address().port} (buttons call ${cfg.answerBase})`);
  }

  log(`watching ${cfg.daemon} → ${cfg.server}/${cfg.topic} as "${cfg.hostName}", kinds: ${[...cfg.kinds].join(', ')}`);
  await check();
  const timer = setInterval(check, cfg.pollMs);
  listen();
  return { server, stop() { stopped.abort(); clearInterval(timer); server?.close(); } };
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  if (process.argv[2] === 'install-hooks') {
    // node pocketrig-watcher.mjs install-hooks /path/to/claude-hook.sh
    const cmd = process.argv[3];
    if (!cmd) { console.error('usage: pocketrig-watcher.mjs install-hooks <hook script>'); process.exit(1); }
    console.log(installClaudeHooks(cmd) ? 'Added PocketRig hooks to Claude Code settings.' : 'Claude Code hooks already in place.');
  } else {
    main().catch((e) => { console.error(e.message); process.exit(1); });
  }
}
