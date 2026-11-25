// node --test host/watcher/watcher.test.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  HOOK_EVENTS, addClaudeHooks, agentLink, answerFix, answerHandler, askSeq, applyHook, attentionAsker, attentionMessage, config, contextPath, installClaudeHooks, lastToolUse, looseMessage, loosePrompt, main, ticket, activityTicket, transcriptAllowed,
  asking, noDialogOnScreen, CHOICE_LINE, needsInput, newlyWaiting, parseAsk, publish, PUBLISH_RETRY_MS, projectOf, pruneLoose, resultMessage, rigStoppedMessage, seatKind, seatLink, seatMessage, snoozedMessage, sseFrames, tokenOk, validSeq,
} from './pocketrig-watcher.mjs';

const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-'));
const cfg = (over = {}) => ({
  topic: 't1', server: 'https://ntfy.sh', hostName: 'homelab',
  answerBase: 'http://homelab.tail1234.ts.net:7434', answerToken: 'tok', kinds: new Set(['permission', 'question', 'blocked']), ...over,
});
const lead = { rigName: 'conveyor', project: 'app', logicalId: 'lead', session: 'lead@conveyor', reason: 'Bash: npm run test:integration', waiting: true };

test('needs-input follows the daemon signals', () => {
  assert.equal(needsInput({ activityState: { needsInput: { count: 1 } } }), true);
  assert.equal(needsInput({ lifecycleState: 'attention_required' }), true);
  assert.equal(needsInput({ arbitratedNeedsInput: true }), true);
  assert.equal(needsInput({ activityState: { needsInput: { count: 0 } } }), false);
  assert.equal(needsInput({}), false);
});

const pane = (name) => fs.readFileSync(fileURLToPath(new URL(`../../test/fixtures/panes/${name}.txt`, import.meta.url)), 'utf8');
const ask = (reason, over = {}) => ({
  runtime: 'claude-code', canonicalSessionName: 'lead@conveyor', activityState: { activity: 'working', needsInput: { count: 1, reason } }, ...over,
});

describe('a permission or question ask needs a dialog on the seat\'s screen', () => {
  test('a screen shows a dialog when it lists numbered choices; an idle or empty one shows none', async () => {
    assert.equal(noDialogOnScreen(pane('permission')), false);
    // Real screens from a Claude Code 2.1.329 session: each must stay waiting.
    for (const real of ['permission_bash', 'question', 'question_option2', 'trust']) {
      assert.equal(noDialogOnScreen(pane(real)), false, real);
      assert.equal(await asking(ask('selection_prompt'), async () => pane(real)), true, real);
    }
    assert.equal(noDialogOnScreen(pane('idle')), true);
    assert.equal(noDialogOnScreen(''), false, 'a failed read proves nothing');
    assert.equal(noDialogOnScreen('Plan:\n  1. First step\n'), false);
  });

  test('the rule is the app\'s, word for word', () => {
    const dart = fs.readFileSync(fileURLToPath(new URL('../../lib/data/prompt_screen.dart', import.meta.url)), 'utf8');
    assert.ok(dart.includes(`RegExp(r'${CHOICE_LINE.source}', multiLine: true)`), 'update lib/data/prompt_screen.dart and CHOICE_LINE together');
  });

  test('no dialog on screen: the daemon\'s held ask is not an ask, so nothing is pushed', async () => {
    for (const reason of ['permission_prompt', 'selection_prompt']) {
      assert.equal(await asking(ask(reason), async () => pane('idle')), false, reason);
    }
    const prev = new Map();
    const waiting = await asking(ask('permission_prompt'), async () => pane('idle'));
    assert.deepEqual(newlyWaiting(prev, [{ key: 'a', waiting }]), []);
    const later = await asking(ask('permission_prompt'), async () => pane('permission'));
    assert.equal(newlyWaiting(prev, [{ key: 'a', waiting: later }]).length, 1, 'the dialog appears: it pushes then');
  });

  test('fails open: a dialog, an unreadable or empty screen, and a throwing read keep the ask', async () => {
    assert.equal(await asking(ask('permission_prompt'), async () => pane('permission')), true);
    assert.equal(await asking(ask('permission_prompt'), async () => null), true);
    assert.equal(await asking(ask('permission_prompt'), async () => ''), true);
    assert.equal(await asking(ask('permission_prompt'), async () => { throw new Error('tmux'); }), true);
  });

  test('reads the screen only for a Claude permission or question ask', async () => {
    const never = async () => { throw new Error('must not read'); };
    assert.equal(await asking(ask('idle_prompt'), never), true);
    assert.equal(await asking(ask('Bash: npm test'), never), true);
    assert.equal(await asking(ask('permission_prompt', { runtime: 'codex' }), never), true);
    assert.equal(await asking({ runtime: 'claude-code', canonicalSessionName: 'a@b' }, never), false, 'not asking at all');
  });
});

test('only false→true transitions notify, and vanished seats reset', () => {
  const prev = new Map();
  assert.deepEqual(newlyWaiting(prev, [{ key: 'a', waiting: true }]).map((s) => s.key), ['a']);
  assert.deepEqual(newlyWaiting(prev, [{ key: 'a', waiting: true }]), []);
  newlyWaiting(prev, [{ key: 'a', waiting: false }]);
  assert.equal(newlyWaiting(prev, [{ key: 'a', waiting: true }]).length, 1);
  newlyWaiting(prev, []);
  assert.equal(prev.size, 0);
});

test('asks, kinds, projects and the role › rig › project › device path', () => {
  assert.deepEqual(parseAsk('Bash: npm test'), { tool: 'Bash', detail: 'npm test' });
  assert.deepEqual(parseAsk('Edit(src/a.ts)'), { tool: 'Edit', detail: 'src/a.ts' });
  assert.deepEqual(parseAsk('asked a question'), { tool: null, detail: 'asked a question' });
  assert.equal(seatKind(lead), 'permission');
  assert.equal(seatKind({ reason: 'asked a question' }), 'question');
  // OpenRig's codes: a permission menu with no tool named is still a permission.
  assert.equal(seatKind({ reason: 'permission_prompt' }), 'permission');
  assert.equal(seatKind({ reason: 'selection_prompt' }), 'question');
  assert.equal(parseAsk('idle_prompt').detail, 'Waiting for your input');
  assert.equal(projectOf([{ cwd: '/w/app' }, { cwd: '/w/app' }, { cwd: '/tmp' }]), 'app');
  assert.equal(projectOf([]), null);
  // A rig that runs in a worktree belongs to the repo, not to the worktree's folder name.
  assert.equal(projectOf([{ cwd: '/w/pocketrig/.claude/worktrees/feature-notifications' }]), 'pocketrig');
  assert.equal(projectOf([{ cwd: '/w/pocketrig/.claude/worktrees/feature-notifications/host' }, { cwd: '/w/pocketrig/.claude/worktrees/feature-notifications/host' }, { cwd: '/tmp' }]), 'pocketrig');
  assert.equal(projectOf([{ cwd: '/w/app/.worktrees/x' }]), 'app');
  assert.equal(projectOf([{ cwd: '/w/worktrees/app' }]), 'app', 'a plain folder called worktrees is not a worktree dir');
  assert.equal(contextPath(cfg(), { project: 'app', rigName: 'conveyor', role: 'lead' }), 'lead › conveyor › app › homelab');
  assert.equal(contextPath(cfg(), { rigName: 'conveyor' }), 'conveyor › homelab');
  assert.equal(seatLink('impl@conveyor', 'mini', 'chat'), 'pocketrig://seat/impl%40conveyor?host=mini&view=chat');
});

test('a permission request: who and what, where, the exact ask; answers first, Open last', () => {
  const m = seatMessage(cfg(), lead, 'pr-seat-x');
  assert.equal(m.title, 'lead needs approval');
  assert.equal(m.message, 'lead › conveyor › app › homelab\nBash · npm run test:integration');
  assert.deepEqual(m.actions.map((a) => a.label), ['Allow once', 'Deny', 'Open']);
  assert.ok(m.actions.length <= 3);
  assert.equal(m.sequence_id, 'pr-seat-x');
  const allow = m.actions[0];
  assert.equal(allow.action, 'http');
  assert.equal(allow.url, 'http://homelab.tail1234.ts.net:7434/answer');
  // The token never leaves the host: the button carries a ticket for this one prompt and this notification.
  assert.equal(allow.headers.Authorization, undefined);
  assert.equal(allow.clear, false, 'the result replaces it; a failed tap leaves the ask up');
  const { ticket: tk, ...answer } = JSON.parse(allow.body);
  assert.deepEqual(answer, { session: 'lead@conveyor', answer: 'allow', seq: 'pr-seat-x' });
  assert.equal(tk, ticket('tok', answer, lead.reason));
  assert.notEqual(tk, ticket('tok', { ...answer, answer: 'deny' }, lead.reason));
  assert.notEqual(tk, ticket('tok', { ...answer, seq: 'pr-seat-other' }, lead.reason), 'the sequence id is signed too');
  assert.equal(m.actions[2].url, 'pocketrig://seat/lead%40conveyor?host=homelab');
  // Without an answer endpoint there are no buttons that would fail.
  assert.deepEqual(seatMessage(cfg({ answerBase: null }), lead).actions.map((a) => a.label), ['Open']);

  // OpenRig's own code: still a permission with Allow once / Deny, the command left to the terminal.
  const p = seatMessage(cfg(), { ...lead, reason: 'permission_prompt' });
  assert.equal(p.title, 'lead needs approval');
  assert.equal(p.message, 'lead › conveyor › app › homelab\nWants to use a tool. The command is in its terminal.');
  assert.deepEqual(p.actions.map((a) => a.label), ['Allow once', 'Deny', 'Open']);
});

test('each ask gets its own valid ntfy sequence id', () => {
  const a = askSeq('seat', 'lead@conveyor', 1000);
  assert.equal(validSeq(a), a);
  assert.ok(a.length <= 64);
  assert.notEqual(askSeq('seat', 'lead@conveyor', 2000), a, 'the same seat asking again is a new notification');
  assert.notEqual(askSeq('seat', 'review@conveyor', 1000), a);
  assert.equal(validSeq('../etc'), null);
  assert.equal(validSeq(42), null);
});

test('a question offers Reply… into the chat; attention items read blocked or question', () => {
  const q = seatMessage(cfg(), { ...lead, logicalId: 'review', session: 'review@conveyor', reason: 'asked a question' });
  assert.equal(q.title, 'review asked a question');
  assert.deepEqual(q.actions.map((a) => a.label), ['Reply…', 'Open']);
  assert.match(q.actions[0].url, /view=chat/);
  const b = attentionMessage(cfg(), {
    id: 'queue:q9', summary: 'Needs the staging key.', asker: 'impl@implementation-pair', answer: { verb: 'resolve' }, project: { root: '/w/site' },
  });
  assert.equal(b.title, 'impl is blocked on you');
  assert.equal(b.message, 'impl › implementation-pair › site › homelab\nNeeds the staging key.');
  assert.deepEqual(b.actions.map((a) => a.label), ['Open', 'Snooze 1 h']);
  assert.deepEqual(JSON.parse(b.actions[1].body), {
    snooze: 'queue:q9', minutes: 60, seq: b.sequence_id,
    ticket: ticket('tok', { snooze: 'queue:q9', minutes: 60, seq: b.sequence_id }),
  });
  const aq = attentionMessage(cfg(), { id: 'queue:q3', summary: 'Squash first?', asker: 'review@conveyor', answer: { verb: 'reply' } });
  assert.equal(aq.title, 'review asked a question');
  assert.deepEqual(aq.actions.map((a) => a.label), ['Reply…', 'Snooze 1 h', 'Open']);
  assert.equal(rigStoppedMessage(cfg(), { name: 'docs-rig', latestSnapshot: 's3' }, 'app').title, 'docs-rig stopped · snapshot s3');
});

test('an item blocked on the person names the queue row\'s seat, not the person', async () => {
  const rows = {
    '/api/queue/q1': { destinationSession: 'orch-pm@sharing', waiting: { owner: 'orch-pm@sharing' } },
    '/api/queue/q2': { destinationSession: 'human@kernel', sourceSession: 'lead@conveyor', waiting: { owner: 'human@kernel' } },
  };
  const get = async (p) => rows[p];
  assert.equal(await attentionAsker({ recipient: 'human@kernel', source: '/api/queue/q1' }, get), 'orch-pm@sharing');
  assert.equal(await attentionAsker({ recipient: 'human@kernel', source: '/api/queue/q2' }, get), 'lead@conveyor');
  assert.equal(await attentionAsker({ asker: 'impl@pair', source: '/api/queue/q1' }, get), 'impl@pair');
  assert.equal(await attentionAsker({ source: '/api/health/x' }, get), null);
  assert.equal(await attentionAsker({ source: '/api/queue/gone' }, async () => { throw new Error('404'); }), null);
});

test('results say what happened, replace the ask, and a failure says what to do', () => {
  assert.equal(resultMessage(cfg(), lead, 'allow', true).title, '✓ Allowed once · lead');
  assert.equal(resultMessage(cfg(), lead, 'allow', true).message, 'lead › conveyor › app › homelab\nRunning npm run test:integration');
  assert.equal(resultMessage(cfg(), lead, 'allow', true).sequence_id, undefined, 'no ask to replace: a new notification');
  assert.equal(resultMessage(cfg(), lead, 'allow', true, null, 'pr-seat-x').sequence_id, 'pr-seat-x');
  assert.equal(resultMessage(cfg(), lead, 'deny', true).title, '✕ Denied · lead');
  const failed = resultMessage(cfg(), lead, 'allow', false, answerFix('not_waiting'), 'pr-seat-x');
  assert.equal(failed.title, "Couldn't answer lead");
  assert.equal(failed.message, 'Already answered, nothing to do.\nlead › conveyor › app › homelab');
  assert.equal(failed.sequence_id, 'pr-seat-x');
  assert.deepEqual(failed.actions.map((a) => a.label), ['Open']);
  assert.match(answerFix('not_in_tmux'), /Restart in tmux/);
  assert.match(answerFix("Couldn't reach the seat: timeout."), /Open it in PocketRig/);
  assert.equal(snoozedMessage(cfg(), 60, 'pr-item-x').title, 'Snoozed for 1 h');
  assert.equal(snoozedMessage(cfg(), 60, 'pr-item-x').sequence_id, 'pr-item-x');
});

test('tokens compare in constant time and must match exactly', () => {
  assert.equal(tokenOk('Bearer tok', 'tok'), true);
  assert.equal(tokenOk('Bearer to', 'tok'), false);
  assert.equal(tokenOk('tok', 'tok'), false);
  assert.equal(tokenOk(undefined, 'tok'), false);
});

test('config: the app-written watcher.json sets name, address and kinds; the token persists', () => {
  const dir = tmp();
  fs.writeFileSync(path.join(dir, 'watcher.json'), JSON.stringify({ hostName: 'homelab', address: 'homelab.tail1234.ts.net', kinds: ['permission', 'rig', 'nonsense'] }));
  const c = config({ POCKETRIG_NTFY_TOPIC: 't1' }, dir);
  assert.equal(c.hostName, 'homelab');
  assert.equal(c.answerBase, 'http://homelab.tail1234.ts.net:7434');
  assert.deepEqual([...c.kinds], ['permission', 'rig']);
  assert.ok(c.answerToken.length >= 24);
  assert.equal(config({ POCKETRIG_NTFY_TOPIC: 't1' }, dir).answerToken, c.answerToken);
  assert.equal((fs.statSync(path.join(dir, 'answer-token')).mode & 0o777).toString(8), '600');
  assert.equal(config({ POCKETRIG_NTFY_TOPIC: 't1', POCKETRIG_ANSWER_PORT: '0' }, dir).answerBase, null);
});

test('SSE frames split on blank lines and keep the remainder', () => {
  const it = sseFrames('id: 1\ndata: {"a":1}\n\ndata: x\r\n\r\ndata: partial');
  const got = [];
  let r;
  while (!(r = it.next()).done) got.push(r.value.data);
  assert.deepEqual(got, ['{"a":1}', 'x']);
  assert.equal(r.value, 'data: partial');
});

/** Runs [handler] on a port and POSTs to it. */
async function call(handler, { auth = 'Bearer tok', body, url = '/answer' }) {
  const server = http.createServer(handler);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  try {
    const res = await fetch(`http://127.0.0.1:${server.address().port}${url}`, {
      method: 'POST', headers: { authorization: auth, 'content-type': 'application/json' }, body: JSON.stringify(body),
    });
    return { status: res.status, body: await res.json() };
  } finally { server.close(); }
}

test('answer endpoint: token, stale buttons, delivery and the follow-up', async () => {
  const sent = [], notes = [], snoozes = [], seqs = [];
  let waiting = true;
  const handler = answerHandler({
    cfg: cfg(), token: 'tok',
    findSeat: async (s) => (s === 'lead@conveyor' ? { ...lead, waiting } : null),
    sendKeys: async (s, a) => { sent.push([s, a]); },
    snooze: (id, m) => snoozes.push([id, m]),
    notify: async (m) => { notes.push(m.title); seqs.push(m.sequence_id); },
  });
  assert.equal((await call(handler, { auth: 'Bearer nope', body: { session: 'lead@conveyor', answer: 'allow' } })).status, 401);
  assert.equal((await call(handler, { body: { session: 'lead@conveyor', answer: 'always' } })).status, 400);
  assert.equal((await call(handler, { body: { session: 'ghost@x', answer: 'allow' } })).status, 404);
  assert.equal((await call(handler, { body: { session: 'lead@conveyor', answer: 'allow', seq: 'pr-seat-1' } })).status, 200);
  assert.deepEqual(sent, [['lead@conveyor', 'allow']]);
  assert.deepEqual(notes, ['✓ Allowed once · lead']);
  assert.deepEqual(seqs, ['pr-seat-1'], 'the result replaces the ask');
  waiting = false;
  assert.equal((await call(handler, { body: { session: 'lead@conveyor', answer: 'deny' } })).status, 409);
  assert.equal(sent.length, 1, 'no keys pressed into a seat that moved on');
  assert.equal(notes.at(-1), "Couldn't answer lead");
  assert.equal((await call(handler, { body: { snooze: 'queue:q9', minutes: 60, seq: 'pr-item-9' } })).status, 200);
  assert.deepEqual(snoozes, [['queue:q9', 60]]);
  assert.equal(notes.at(-1), 'Snoozed for 1 h');
  assert.equal(seqs.at(-1), 'pr-item-9');
});

test('answer endpoint: a button only answers the prompt it was sent for', async () => {
  const sent = [], notes = [];
  let reason = 'Bash: npm test';
  const handler = answerHandler({
    cfg: cfg(), token: 'tok',
    findSeat: async () => ({ ...lead, waiting: true, reason }),
    sendKeys: async (s, a) => { sent.push([s, a]); },
    snooze: () => {},
    notify: async (m) => notes.push(m.message),
  });
  const body = { session: 'lead@conveyor', answer: 'allow' };
  const tk = ticket('tok', body, 'Bash: npm test');
  // No token and no ticket; a ticket made with another token; a deny ticket used to allow.
  assert.equal((await call(handler, { auth: '', body })).status, 401);
  assert.equal((await call(handler, { auth: '', body: { ...body, ticket: ticket('other', body, reason) } })).status, 409);
  assert.equal((await call(handler, { auth: '', body: { ...body, ticket: ticket('tok', { ...body, answer: 'deny' }, reason) } })).status, 409);
  // The seat moved on to another prompt: the old button presses nothing.
  reason = 'Bash: rm -rf /';
  assert.equal((await call(handler, { auth: '', body: { ...body, ticket: tk } })).status, 409);
  assert.deepEqual(sent, []);
  assert.match(notes.at(-1), /asking something else/);
  reason = 'Bash: npm test';
  assert.equal((await call(handler, { auth: '', body: { ...body, ticket: tk } })).status, 200);
  assert.deepEqual(sent, [['lead@conveyor', 'allow']]);
  // Snooze without the token needs its own ticket.
  assert.equal((await call(handler, { auth: '', body: { snooze: 'q1', minutes: 60, ticket: tk } })).status, 401);
});

test('answer endpoint: a ticket answers once; a retry after success is refused', async () => {
  const sent = [];
  let fail = true;
  const handler = answerHandler({
    cfg: cfg(), token: 'tok',
    findSeat: async () => ({ ...lead, waiting: true }),
    sendKeys: async (s, a) => { if (fail) throw new Error('tmux down'); sent.push([s, a]); },
    snooze: () => {},
    notify: async () => {},
  });
  const body = { session: 'lead@conveyor', answer: 'allow' };
  const tk = { auth: '', body: { ...body, ticket: ticket('tok', body, lead.reason) } };
  assert.equal((await call(handler, tk)).status, 502, 'nothing pressed, so the ticket is not used up');
  fail = false;
  assert.equal((await call(handler, tk)).status, 200);
  assert.equal((await call(handler, tk)).status, 409, 'the same ticket cannot approve a later identical prompt');
  assert.deepEqual(sent, [['lead@conveyor', 'allow']]);
});

test('answer endpoint: a forged button can\'t replace a notification', async () => {
  const seqs = [];
  let waiting = false;
  const handler = answerHandler({
    cfg: cfg(), token: 'tok',
    findSeat: async () => ({ ...lead, waiting }),
    sendKeys: async () => {},
    snooze: () => {},
    notify: async (m) => seqs.push(m.sequence_id),
  });
  const body = { session: 'lead@conveyor', answer: 'allow', seq: 'pr-seat-victim' };
  // Not waiting, bogus ticket: the "couldn't answer" note posts fresh, it doesn't overwrite pr-seat-victim.
  assert.equal((await call(handler, { auth: '', body: { ...body, ticket: 'forged' } })).status, 409);
  assert.deepEqual(seqs, [undefined]);
  // A ticket that signs a different sequence id doesn't carry over to this one.
  waiting = true;
  const other = ticket('tok', { ...body, seq: 'pr-seat-mine' }, lead.reason);
  assert.equal((await call(handler, { auth: '', body: { ...body, ticket: other } })).status, 409);
  assert.equal(seqs.at(-1), undefined);
});

test('a hook can only point the watcher at Claude transcripts', () => {
  const root = tmp(), other = tmp();
  fs.writeFileSync(path.join(root, 'a.jsonl'), '');
  fs.writeFileSync(path.join(other, 'b.jsonl'), '');
  fs.writeFileSync(path.join(root, 'secret.txt'), '');
  assert.ok(transcriptAllowed(path.join(root, 'a.jsonl'), [root]));
  assert.ok(!transcriptAllowed(path.join(other, 'b.jsonl'), [root]));
  assert.ok(!transcriptAllowed(path.join(root, 'secret.txt'), [root]));
  assert.ok(!transcriptAllowed(path.join(root, '..', path.basename(other), 'b.jsonl'), [root]));
  fs.symlinkSync(path.join(other, 'b.jsonl'), path.join(root, 'link.jsonl'));
  assert.ok(!transcriptAllowed(path.join(root, 'link.jsonl'), [root]), 'symlinks out are refused');
});

test('hook events track agents outside a rig', () => {
  const reg = new Map();
  const base = { session_id: 's1', cwd: '/Users/me/code/app', transcript_path: '/t/s1.jsonl' };
  // A session resumed in tmux is listed before its first prompt.
  assert.ok(HOOK_EVENTS.includes('SessionStart'));
  assert.equal(applyHook(reg, { ...base, hook_event_name: 'SessionStart' }, { pane: '%3', tmux: 'scratch' }), null);
  assert.equal(reg.get('s1').tmux, 'scratch');
  assert.equal(applyHook(reg, { ...base, hook_event_name: 'UserPromptSubmit' }, { pane: '%3', tmux: 'scratch' }), null);
  assert.equal(reg.get('s1').tmux, 'scratch');
  assert.equal(reg.get('s1').activity, 'working');
  applyHook(reg, { ...base, hook_event_name: 'Stop' }, {}, 1000);
  assert.equal(reg.get('s1').activity, 'idle');
  // An idle reminder isn't a request, and isn't activity either.
  assert.equal(applyHook(reg, { ...base, hook_event_name: 'Notification', message: 'Claude is waiting for your input' }, {}, 9000), null);
  assert.equal(reg.get('s1').waiting, false);
  assert.equal(reg.get('s1').activeAt, 1000);
  assert.ok(HOOK_EVENTS.includes('PreToolUse'));
  const a = applyHook(reg, { ...base, hook_event_name: 'Notification', message: 'Claude needs your permission to use Bash' });
  assert.equal(a.kind, 'permission');
  assert.equal(a.pane, '%3', 'pane is remembered from earlier events');
  // The same prompt again doesn't notify twice.
  assert.equal(applyHook(reg, { ...base, hook_event_name: 'Notification', message: 'Claude needs your permission to use Bash' }), null);
  // The next tool starting doesn't answer the prompt; one finishing does.
  applyHook(reg, { ...base, hook_event_name: 'PreToolUse' });
  assert.equal(reg.get('s1').waiting, true);
  assert.equal(reg.get('s1').activity, 'working');
  applyHook(reg, { ...base, hook_event_name: 'PostToolUse' });
  assert.equal(reg.get('s1').waiting, false);
  pruneLoose(reg, Date.now() + 25 * 3600e3);
  assert.equal(reg.size, 0, 'idle agents age out after a day');
  applyHook(reg, { ...base, hook_event_name: 'Stop' });
  applyHook(reg, { ...base, hook_event_name: 'SessionEnd' });
  assert.equal(reg.size, 0);
  assert.equal(applyHook(reg, { hook_event_name: 'Stop' }), null, 'no session id, ignored');
});

test('the command an agent is asking about comes from its transcript', () => {
  const tail = [
    JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: '/a.ts' } }] } }),
    JSON.stringify({ type: 'user', message: { content: [{ type: 'tool_result', content: 'ok' }] } }),
    JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: 'Building' }, { type: 'tool_use', name: 'Bash', input: { command: 'rm -rf dist && npm run build\necho done' } }] } }),
    '{"partial',
  ].join('\n');
  assert.deepEqual(lastToolUse(tail), { tool: 'Bash', detail: 'rm -rf dist && npm run build' });
  assert.equal(lastToolUse('nothing here'), null);
});

test('agents outside a rig: path, actions and links', () => {
  const inTmux = { id: 's1', cwd: '/Users/me/code/app', tmux: 'scratch', pane: '%3', tool: 'Bash', detail: 'rm -rf dist' };
  const m = looseMessage(cfg(), inTmux);
  assert.equal(m.title, 'scratch needs approval');
  assert.equal(m.message, 'scratch › no rig › app › homelab\nBash · rm -rf dist');
  assert.deepEqual(m.actions.map((a) => a.label), ['Allow once', 'Deny', 'Open']);
  assert.deepEqual(JSON.parse(m.actions[0].body), {
    loose: 's1', answer: 'allow', seq: m.sequence_id,
    ticket: ticket('tok', { loose: 's1', answer: 'allow', seq: m.sequence_id }, loosePrompt(inTmux)),
  });
  assert.equal(agentLink(inTmux, 'homelab'), 'pocketrig://agent/s1?host=homelab&tmux=scratch&cwd=%2FUsers%2Fme%2Fcode%2Fapp');

  const tab = { id: 's2', cwd: '/Users/me/code/site', message: 'Claude needs your permission to use Edit' };
  const t = looseMessage(cfg(), tab);
  assert.equal(t.title, 'claude needs approval');
  assert.equal(t.message, 'claude › no rig › site › homelab\nClaude needs your permission to use Edit. Not in tmux, so answer it at the Mac.');
  assert.deepEqual(t.actions.map((a) => a.label), ['Open chat']);
});

test('Claude Code hooks are added once and keep other settings', () => {
  const settings = { model: 'opus', hooks: { Stop: [{ matcher: '', hooks: [{ type: 'command', command: 'say done' }] }] } };
  assert.equal(addClaudeHooks(settings, '/x/claude-hook.sh'), true);
  assert.equal(addClaudeHooks(settings, '/x/claude-hook.sh'), false);
  assert.equal(settings.model, 'opus');
  assert.equal(settings.hooks.Stop.length, 2);
  assert.deepEqual(Object.keys(settings.hooks).sort(), ['Notification', 'PostToolUse', 'PreToolUse', 'SessionEnd', 'SessionStart', 'Stop', 'UserPromptSubmit']);
});

test('a PocketRig hook at an old path is replaced; hooks that only look alike stay', () => {
  const old = '/Users/me/PocketRig/host/watcher/claude-hook.sh';
  const moshi = "'/Users/me/.local/bin/moshi-hook' claude-hook";
  const other = '/opt/tools/claude-hook.sh';
  const settings = {
    hooks: {
      Stop: [
        { matcher: '', hooks: [{ type: 'command', command: old }] },
        { matcher: '', hooks: [{ type: 'command', command: moshi }, { type: 'command', command: old }] },
        { matcher: '', hooks: [{ type: 'command', command: other }] },
      ],
    },
  };
  const now = '/Users/me/.config/pocketrig/claude-hook.sh';
  assert.equal(addClaudeHooks(settings, now), true);
  assert.deepEqual(settings.hooks.Stop.flatMap((m) => m.hooks.map((h) => h.command)), [moshi, other, now]);
  assert.equal(addClaudeHooks(settings, now), false);
});

test('installing hooks backs up settings and refuses a file it cannot parse', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-hooks-'));
  try {
    const file = path.join(dir, 'settings.json');
    fs.writeFileSync(file, '{"model":"opus"}');
    assert.equal(installClaudeHooks('/x/claude-hook.sh', file), true);
    assert.equal(fs.readFileSync(`${file}.pocketrig-backup`, 'utf8'), '{"model":"opus"}');
    assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).model, 'opus');
    fs.writeFileSync(file, '{broken');
    assert.throws(() => installClaudeHooks('/y/claude-hook.sh', file));
    assert.equal(fs.readFileSync(file, 'utf8'), '{broken', 'left as it was');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe('install.sh', () => {
  const script = fileURLToPath(new URL('./install.sh', import.meta.url));
  /** Runs install.sh with a fake launchctl that fails the listed subcommands. */
  function run(failing = []) {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketrig-install-'));
    const bin = path.join(home, 'bin');
    fs.mkdirSync(bin);
    const log = path.join(home, 'launchctl.log');
    const cases = failing.map((c) => `  ${c}) exit 1 ;;\n`).join('');
    fs.writeFileSync(path.join(bin, 'launchctl'), `#!/bin/sh\necho "$1" >> "${log}"\ncase "$1" in\n${cases}esac\n`, { mode: 0o755 });
    const r = spawnSync('sh', [script, 'topic-1', 'https://ntfy.sh', 'mini'], {
      encoding: 'utf8',
      env: { HOME: home, PATH: `${bin}:${path.dirname(process.execPath)}:/usr/bin:/bin` },
    });
    return { ...r, home, plist: path.join(home, 'Library/LaunchAgents/dev.pocketrig.watcher.plist'), settings: path.join(home, '.claude/settings.json'), calls: () => fs.readFileSync(log, 'utf8').trim().split('\n') };
  }

  test('without a desktop session nothing changes and the running watcher is left alone', () => {
    const r = run(['print']);
    try {
      assert.equal(r.status, 1);
      assert.match(r.stderr, /Log in at the Mac/);
      assert.deepEqual(r.calls(), ['print'], 'no bootout, no bootstrap');
      assert.equal(fs.existsSync(r.plist), false);
      assert.equal(fs.existsSync(r.settings), false);
    } finally { fs.rmSync(r.home, { recursive: true, force: true }); }
  });

  test('a refused start reports the command to run at the Mac and adds no hooks', () => {
    const r = run(['bootstrap']);
    try {
      assert.equal(r.status, 1);
      assert.match(r.stderr, /At the Mac, run: sh .*install\.sh" topic-1/);
      assert.equal(fs.existsSync(r.settings), false);
    } finally { fs.rmSync(r.home, { recursive: true, force: true }); }
  });

  test('success registers the watcher and the hooks', () => {
    const r = run();
    try {
      assert.equal(r.status, 0, r.stderr);
      assert.deepEqual(r.calls(), ['print', 'bootout', 'bootstrap']);
      assert.match(fs.readFileSync(r.plist, 'utf8'), /topic-1/);
      assert.ok(JSON.parse(fs.readFileSync(r.settings, 'utf8')).hooks.SessionStart);
    } finally { fs.rmSync(r.home, { recursive: true, force: true }); }
  });
});

test('end to end: a waiting seat posts a notification whose Allow button reaches the seat', { timeout: 20000 }, async () => {
  let waiting = false;
  let sse = null;
  const daemon = http.createServer((req, res) => {
    const json = (v) => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(v)); };
    if (req.url === '/api/ps') return json([{ rigId: 'r1', name: 'conveyor', status: 'running' }]);
    if (req.url === '/api/rigs/r1/nodes') {
      return json([{ logicalId: 'lead', canonicalSessionName: 'lead@conveyor', cwd: '/Users/me/code/app',
        activityState: { needsInput: { count: waiting ? 1 : 0, reason: waiting ? 'Bash: npm run test:integration' : null } } }]);
    }
    if (req.url === '/api/attention') return json({ items: [] });
    if (req.url.startsWith('/api/events')) { res.writeHead(200, { 'content-type': 'text/event-stream' }); sse = res; return; }
    res.statusCode = 404; res.end();
  });
  const posts = [];
  let gotPost;
  let posted = new Promise((r) => { gotPost = r; });
  const ntfy = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => { posts.push(JSON.parse(body)); res.end('{}'); gotPost(); });
  });
  await new Promise((r) => daemon.listen(0, '127.0.0.1', r));
  await new Promise((r) => ntfy.listen(0, '127.0.0.1', r));
  const dir = tmp();
  fs.writeFileSync(path.join(dir, 'watcher.json'), JSON.stringify({ hostName: 'homelab', address: '127.0.0.1' }));
  const keys = [];
  let w;
  try {
    w = await main({
      POCKETRIG_NTFY_TOPIC: 'test-topic',
      POCKETRIG_NTFY_SERVER: `http://127.0.0.1:${ntfy.address().port}`,
      OPENRIG_URL: `http://127.0.0.1:${daemon.address().port}`,
      POCKETRIG_POLL_MS: '60000',
      POCKETRIG_ANSWER_PORT: '0',
    }, { configDir: dir, sendKeys: async (s, a) => keys.push([s, a]) });
    assert.equal(w.server, null, 'port 0 turns the endpoint off');
    w.stop();

    // Now with the endpoint on, on a free port.
    const port = await new Promise((r) => { const s = http.createServer(); s.listen(0, () => { const p = s.address().port; s.close(() => r(p)); }); });
    w = await main({
      POCKETRIG_NTFY_TOPIC: 'test-topic',
      POCKETRIG_NTFY_SERVER: `http://127.0.0.1:${ntfy.address().port}`,
      OPENRIG_URL: `http://127.0.0.1:${daemon.address().port}`,
      POCKETRIG_POLL_MS: '60000',
      POCKETRIG_ANSWER_PORT: String(port),
      POCKETRIG_ANSWER_BIND: '127.0.0.1',
    }, { configDir: dir, transcriptRoots: [dir], sendKeys: async (s, a) => keys.push([s, a]), sendPaneKeys: async (p, a) => keys.push([p, a]) });
    for (let i = 0; i < 50 && !sse; i++) await new Promise((r) => setTimeout(r, 50));
    const t0 = Date.now();
    waiting = true;
    sse.write(`id: 9\ndata: ${JSON.stringify({ type: 'seat.activity_changed', sessionName: 'lead@conveyor', seq: 9 })}\n\n`);
    await posted;
    assert.ok(Date.now() - t0 < 10000);
    const n = posts.at(-1);
    assert.equal(n.topic, 'test-topic');
    assert.equal(n.title, 'lead needs approval');
    assert.equal(n.message, 'lead › conveyor › app › homelab\nBash · npm run test:integration');

    // Tap "Allow once": the phone POSTs exactly what the action carries.
    posted = new Promise((r) => { gotPost = r; });
    const allow = n.actions[0];
    const res = await fetch(allow.url, { method: allow.method, headers: allow.headers, body: allow.body });
    assert.equal(res.status, 200);
    assert.deepEqual(keys, [['lead@conveyor', 'allow']]);
    await posted;
    assert.equal(posts.at(-1).title, '✓ Allowed once · lead');
    assert.equal(posts.at(-1).sequence_id, n.sequence_id, 'the result replaces the notification');

    // An agent started by hand in tmux: the Claude hook reports it.
    const hook = (body, pane, tmux) => fetch(`http://127.0.0.1:${port}/hook`, {
      method: 'POST', body: JSON.stringify(body),
      headers: { Authorization: `Bearer ${fs.readFileSync(path.join(dir, 'answer-token'), 'utf8').trim()}`, 'X-Tmux-Pane': pane, 'X-Tmux-Session': tmux },
    });
    const transcript = path.join(dir, 's9.jsonl');
    fs.writeFileSync(transcript, `${JSON.stringify({ message: { content: [{ type: 'tool_use', name: 'Bash', input: { command: 'rm -rf dist' } }] } })}\n`);
    // A rig seat's own hook is left to the daemon.
    assert.equal((await hook({ session_id: 'seat', hook_event_name: 'Notification', message: 'Claude needs your permission to use Bash' }, '%1', 'lead@conveyor')).status, 200);
    posted = new Promise((r) => { gotPost = r; });
    const before = posts.length;
    assert.equal((await hook({ session_id: 's9', cwd: '/Users/me/code/app', transcript_path: transcript, hook_event_name: 'Notification',
      message: 'Claude needs your permission to use Bash' }, '%7', 'scratch')).status, 200);
    await posted;
    assert.equal(posts.length, before + 1, 'only the loose agent notified');
    const ln = posts.at(-1);
    assert.equal(ln.message, 'scratch › no rig › app › homelab\nBash · rm -rf dist');
    const saved = JSON.parse(fs.readFileSync(path.join(dir, 'loose.json'), 'utf8'));
    assert.deepEqual(saved.map((a) => [a.id, a.tmux, a.waiting]), [['s9', 'scratch', true]]);
    posted = new Promise((r) => { gotPost = r; });
    const lallow = ln.actions[0];
    assert.equal((await fetch(lallow.url, { method: 'POST', headers: lallow.headers, body: lallow.body })).status, 200);
    assert.deepEqual(keys.at(-1), ['%7', 'allow']);
    await posted;
    assert.equal(posts.at(-1).title, '✓ Allowed once · scratch');
    // Tapping again: it isn't waiting any more.
    assert.equal((await fetch(lallow.url, { method: 'POST', headers: lallow.headers, body: lallow.body })).status, 409);
  } finally {
    w?.stop();
    sse?.end();
    daemon.closeAllConnections();
    daemon.close();
    ntfy.close();
    setTimeout(() => process.exit(0), 50).unref();
  }
});

test('a failed ntfy post is retried, then given up on', async () => {
  const cfg = { server: 'https://ntfy.example', token: null };
  let calls = 0;
  const waits = [];
  const sleep = async (ms) => { waits.push(ms); };
  const flaky = async () => { calls++; if (calls < 3) throw new TypeError('fetch failed'); return { ok: true }; };
  assert.equal(await publish(cfg, { topic: 't' }, { fetchImpl: flaky, sleep }), true);
  assert.equal(calls, 3);
  assert.deepEqual(waits, PUBLISH_RETRY_MS);

  calls = 0;
  const down = async () => { calls++; throw new TypeError('fetch failed'); };
  assert.equal(await publish(cfg, { topic: 't' }, { fetchImpl: down, sleep }), false);
  assert.equal(calls, PUBLISH_RETRY_MS.length + 1);

  // A refusal (bad topic, auth) is an answer, not a dropped connection: no retry.
  calls = 0;
  const refused = async () => { calls++; return { ok: false, status: 403, text: async () => 'forbidden' }; };
  assert.equal(await publish(cfg, { topic: 't' }, { fetchImpl: refused, sleep }), false);
  assert.equal(calls, 1);
});

test('activity token endpoint: only a ticket made for that start stores the token', async () => {
  const got = [];
  const handler = answerHandler({
    cfg: cfg(), token: 'tok',
    activityToken: (id, t) => { if (id !== 'abc123') return false; got.push(t); return true; },
  });
  const post = (url, body) => call(handler, { auth: '', url, body });
  const tk = activityTicket('tok', 'abc123');
  assert.equal((await post('/activity-token?start=abc123', { token: 'ab12cd34ef56ab12', ticket: tk })).status, 200);
  assert.deepEqual(got, ['ab12cd34ef56ab12']);
  assert.equal((await post('/activity-token?start=abc123', { token: 'ab12cd34ef56ab12', ticket: 'forged' })).status, 401);
  assert.equal((await post('/activity-token?start=abc123', { token: 'ab12cd34ef56ab12', ticket: activityTicket('other', 'abc123') })).status, 401);
  assert.equal((await post('/activity-token?start=zzz', { token: 'ab12cd34ef56ab12', ticket: tk })).status, 401, 'a ticket is for its own start');
  assert.equal((await post('/activity-token?start=zzz', { token: 'ab12cd34ef56ab12', ticket: activityTicket('tok', 'zzz') })).status, 404, 'a start this watcher did not make');
  assert.equal((await post('/activity-token?start=abc123', { token: 'not hex!', ticket: tk })).status, 400);
  assert.deepEqual(got, ['ab12cd34ef56ab12'], 'nothing stored by the refused posts');
  // a swipe-away report is no longer a thing: {ended} without a token is just a bad post
  assert.equal((await post('/activity-token?start=abc123', { ended: true, ticket: tk })).status, 400);
  assert.deepEqual(got, ['ab12cd34ef56ab12']);
});
