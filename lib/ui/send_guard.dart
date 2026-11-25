import 'package:flutter/material.dart';

import '../data/prompt_screen.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';
import 'kit.dart' show confirmSheet;
import 'theme.dart';

/// Text typed into Claude's prompt while its AskUserQuestion menu or a permission dialog is open becomes the answer. Over SSH
/// (a loose agent, a typed answer) nothing stops that. Through the daemon's send, a rig seat the daemon KNOWS is at a prompt is
/// refused (409 `target_needs_input`, "a message must not select or approve it": daemon/dist/domain/session-transport.js), so the
/// risk is a menu the daemon has not classified yet, an older daemon, and a send that overrides it. Hence this check stays, ahead of
/// every send. Whether [seat] has such a dialog open now: see [seatsWithOpenQuestion].
Future<bool> seatHasOpenQuestion(Host host, Seat seat) async => (await seatsWithOpenQuestion(host, [seat])).isNotEmpty;

/// The [seats] with a dialog open: the daemon says one needs a person (and its screen does not show it clear), or the screen,
/// read over SSH (one call for all of them), shows one. When the screen can't be read (no key, SSH failed, empty output) the
/// daemon's word stands: a seat it says asks is never taken for clear.
Future<Set<Seat>> seatsWithOpenQuestion(Host host, Iterable<Seat> seats) async {
  final open = <Seat>{};
  final toRead = <Seat>[];
  for (final s in seats) {
    if (s.needsInput) {
      open.add(s);
    } else if (s.sessionName != null && s.isClaude && s.state != SeatState.stopped) {
      if (!host.isLocal && host.privateKeyPem == null) {
        if (s.daemonAsks) open.add(s);
      } else {
        toRead.add(s);
      }
    }
  }
  if (toRead.isEmpty) return open;
  var screens = const <String, String>{};
  try {
    final out = await SshExec.use(host, (ssh) => ssh.runLogin(screensScript([for (final s in toRead) s.sessionName!])));
    screens = screensBySession(out);
  } catch (_) {/* unreadable: the daemon's word stands */}
  for (final s in toRead) {
    final screen = screens[s.sessionName];
    if (screen == null || screen.trim().isEmpty ? s.daemonAsks : dialogOnScreen(screen)) open.add(s);
  }
  return open;
}

/// Before typing into seats nobody could list: "Can't check whether anyone is showing a question". True for Send anyway.
Future<bool> confirmUnchecked(BuildContext context) => confirmSheet(context,
    title: 'Can\'t check whether anyone is showing a question',
    body: 'A message now would answer any question a seat has open.',
    action: 'Send anyway',
    destructive: false);

enum SendGuard { send, answer, cancel }

/// Before typing into [seat]: if it has a question or dialog open, says so and asks. [SendGuard.send] when nothing is open or
/// "Send anyway" was chosen; [SendGuard.answer] for "Answer in Chat" (the caller opens the chat; [inChat] true when this is
/// the chat, where the choice reads "Cancel" and the answer card is already on screen); [SendGuard.cancel] otherwise.
Future<SendGuard> askBeforeSending(BuildContext context, Host host, Seat seat, {bool inChat = false}) async {
  if (!await seatHasOpenQuestion(host, seat)) return SendGuard.send;
  // The screen it was asked from has gone: nothing to answer, and nothing was confirmed.
  if (!context.mounted) return SendGuard.cancel;
  final k = Tokens.of(context);
  final name = seat.logicalId;
  final choice = await showModalBottomSheet<SendGuard>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('$name is showing a question', style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('A message now would answer it.', style: TextStyle(fontSize: 14, color: k.muted)),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, inChat ? SendGuard.cancel : SendGuard.answer),
              style: sheetAction,
              child: Text(inChat ? 'Cancel' : 'Answer in Chat')),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: () => Navigator.pop(ctx, SendGuard.send), style: sheetAction, child: const Text('Send anyway')),
        ]),
      ),
    ),
  );
  return choice ?? SendGuard.cancel;
}
