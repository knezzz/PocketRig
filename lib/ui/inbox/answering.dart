import 'package:flutter/material.dart';

import '../../chat/transcript.dart';
import '../../data/chat_cache.dart';
import '../../data/fleet.dart';
import '../../data/loose_agents.dart';
import '../../main.dart';
import '../../models.dart';
import '../../terminal/transport.dart';
import '../chat/question_card.dart';
import '../common.dart';
import '../kit.dart';
import '../needs_you_banner.dart';
import '../permission_card.dart';
import '../theme.dart';

/// What a waiting seat's own log says about its ask: the call that is
/// waiting (the exact command), its questions when it's an AskUserQuestion,
/// and the task it's on. Read from the chat cache, so it costs no SSH.
class PendingAsk {
  PendingAsk({this.call, this.questions, this.task, this.recent = const []});

  /// The newest call without a result: what the permission prompt is for.
  final ToolCall? call;
  final List<AskQuestion>? questions;

  /// The to-do item marked in progress, if the seat keeps a list.
  final String? task;

  /// The last few lines of what the agent did before it asked, oldest first: a command or tool and its result (said:
  /// false), or the agent's own words (said: true). From the same cached log the ask is read from.
  final List<(String, bool)> recent;

  /// The exact command, file or address the call wants.
  String? get command {
    final c = call;
    if (c == null || c.name == 'AskUserQuestion') return null;
    String? s(String k) => switch (c.input[k]) { final String v when v.trim().isNotEmpty => v.trim(), _ => null };
    return switch (c.name) {
      'Bash' => s('command'),
      _ => s('file_path') ?? s('notebook_path') ?? s('url') ?? s('command') ?? s('path') ?? s('pattern') ?? s('query'),
    };
  }

  /// The call's own reason ("Run the unit suite once"), when it gave one.
  String? get why => switch (call?.input['description']) { final String v when v.trim().isNotEmpty => v.trim(), _ => null };

  static PendingAsk? fromLines(List<String> lines) {
    if (lines.isEmpty) return null;
    final t = ChatTranscript()..addAll(lines);
    final calls = t.items.whereType<ToolCall>().toList();
    final waiting = switch (calls.lastOrNull) { final c? when !c.done => c, _ => null };
    String? task;
    for (final c in calls.reversed) {
      if (c.name != 'TodoWrite') continue;
      final todos = c.input['todos'];
      if (todos is List) {
        for (final t in todos) {
          if (t is Map && t['status'] == 'in_progress') {
            task = '${t['content'] ?? t['activeForm'] ?? ''}'.trim();
            break;
          }
        }
      }
      break;
    }
    final out = <(String, bool)>[];
    for (final i in t.items) {
      switch (i) {
        case ToolCall c when !identical(c, waiting):
          out.add((c.name == 'Bash' ? '\$ ${c.target}' : '${c.verb.toLowerCase()} ${c.target}'.trim(), false));
          if (c.done) out.add((c.shortResult, false));
        case AssistantMessage m when m.text.trim().isNotEmpty:
          out.add((m.text.trim().split('\n').first, true));
        default:
      }
    }
    return PendingAsk(
        call: waiting,
        questions: AskQuestion.from(waiting),
        task: task?.isEmpty ?? true ? null : task,
        recent: out.length > 6 ? out.sublist(out.length - 6) : out);
  }

  /// [seat]'s pending ask from the chat cache; null without a cache or log.
  static Future<PendingAsk?> load(Host host, Seat seat) async {
    final cache = chatCache;
    if (cache == null) return null;
    try {
      return fromLines(await cache.lastLines(host.id, chatKey(seat), 80));
    } catch (_) {
      return null;
    }
  }
}

/// What a permission card shows and how Always is scoped: the daemon's
/// reason, sharpened by the call in the log when the daemon only knows a
/// menu is up.
PermissionAsk askOf(Seat seat, PendingAsk? pending) {
  final ask = PermissionAsk.from(seat);
  final call = pending?.call;
  final cmd = pending?.command;
  if (call == null || cmd == null || !ask.isPermission) return ask;
  if (ask.tool == null || ask.tool == call.name) return PermissionAsk(tool: call.name, detail: cmd);
  return ask;
}

/// "Allowed once", "Denied"… for the toast after [a].
String answerLabel(SeatAnswer a, {String? scope}) => switch (a) {
      SeatAnswer.allowOnce => 'Allowed once',
      SeatAnswer.allowAlways => scope == null ? 'Always allowed' : 'Always allowed “$scope”',
      SeatAnswer.deny => 'Denied',
    };

/// Answers [seat] on [host] (any host, not only the active one) the way the
/// terminal would, says so in a toast, and takes its banner down. True when sent.
Future<bool> answerSeatOn(BuildContext context, Host host, Seat seat, SeatAnswer a,
    {String? scope, VoidCallback? onOpen}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final k = Tokens.of(context);
  try {
    await answerSeat(host, seat, a);
    needsYouAlerts.answered(seat);
    if (messenger != null) {
      toastOn(messenger, k, '${answerLabel(a, scope: scope)} · ${seat.logicalId}',
          kind: ToastKind.done, action: onOpen == null ? null : 'Open', onAction: onOpen);
    }
    fleet.feedFor(host).refresh();
    return true;
  } catch (e) {
    if (messenger != null) toastOn(messenger, k, 'Couldn\'t answer ${seat.logicalId}: $e', kind: ToastKind.problem);
    return false;
  }
}

/// Deny, then ask what [seat] should do instead and send it. [sheetContext]
/// must sit under a Navigator (the banner floats above it).
Future<bool> denyWithNoteOn(BuildContext context, Host host, Seat seat, {BuildContext? sheetContext}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final k = Tokens.of(context);
  if (!await answerSeatOn(context, host, seat, SeatAnswer.deny)) return false;
  final ctx = sheetContext ?? context;
  if (!ctx.mounted) return true;
  final note = await inputSheet(ctx,
      title: 'Tell ${seat.logicalId} what to do instead', action: 'Send', cancel: 'Skip', lines: 2);
  if (note == null || note.trim().isEmpty) return true;
  await sendTo(messenger, k, host, seat, note.trim(), 'Sent to ${seat.logicalId}');
  return true;
}

/// Allow once, then switch the live conversation to Auto and save Auto for
/// the seat's next launch, like the chat's "Allow & switch to auto".
Future<bool> allowAndAutoOn(BuildContext context, Host host, Seat seat) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final k = Tokens.of(context);
  try {
    await answerSeat(host, seat, SeatAnswer.allowOnce);
    needsYouAlerts.answered(seat);
  } catch (e) {
    if (messenger != null) toastOn(messenger, k, 'Couldn\'t answer ${seat.logicalId}: $e', kind: ToastKind.problem);
    return false;
  }
  await Future<void>.delayed(const Duration(milliseconds: 500)); // let the menu close
  try {
    await switchSeatToAuto(host, seat);
    await AppScope.clientFor(host).setPermissionMode(seat, PermissionMode.auto);
    if (messenger != null) toastOn(messenger, k, 'Allowed once · ${seat.logicalId} now in Auto', kind: ToastKind.done);
  } catch (e) {
    if (messenger != null) {
      toastOn(messenger, k, 'Allowed once · couldn\'t switch ${seat.logicalId} to Auto: $e', kind: ToastKind.problem);
    }
  }
  fleet.feedFor(host).refresh();
  return true;
}

/// Types [text] into [seat] through the daemon.
Future<bool> sendTo(ScaffoldMessengerState? messenger, Tokens k, Host host, Seat seat, String text, String done) async {
  final session = seat.sessionName;
  if (session == null) return false;
  try {
    await AppScope.clientFor(host).send(session, text);
    if (messenger != null) toastOn(messenger, k, done, kind: ToastKind.done);
    fleet.feedFor(host).refresh();
    return true;
  } catch (e) {
    if (messenger != null) toastOn(messenger, k, 'Couldn\'t send to ${seat.logicalId}: $e', kind: ToastKind.problem);
    return false;
  }
}

/// Answers an AskUserQuestion menu. Picked options go as the menu's own
/// number keys; when any answer is typed ("Other"), the menu is declined and
/// every answer goes as one message instead, which the agent reads the same.
Future<bool> sendQuestionAnswers(BuildContext context, Host host, Seat seat, List<AskQuestion> qs,
    List<Set<int>> picks, List<String> others) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final k = Tokens.of(context);
  final api = AppScope.clientFor(host);
  final typed = others.any((o) => o.trim().isNotEmpty);
  try {
    if (!typed) {
      await pressSeatKeys(host, seat, questionKeys(qs, picks));
    } else {
      await answerSeat(host, seat, SeatAnswer.deny);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await api.send(seat.sessionName!, [
        'My answers:',
        for (var i = 0; i < qs.length; i++)
          '${i + 1}. ${qs[i].question} → ${others[i].trim().isNotEmpty ? others[i].trim() : (picks[i].toList()..sort()).map((o) => qs[i].options[o].$1).join(', ')}',
      ].join('\n'));
    }
    needsYouAlerts.answered(seat);
    if (messenger != null) {
      toastOn(messenger, k, '${qs.length > 1 ? 'Answers sent' : 'Answer sent'} · ${seat.logicalId}', kind: ToastKind.done);
    }
    fleet.feedFor(host).refresh();
    return true;
  } catch (e) {
    if (messenger != null) toastOn(messenger, k, 'Couldn\'t answer ${seat.logicalId}: $e', kind: ToastKind.problem);
    return false;
  }
}

/// Allow or deny an agent outside a rig, through its tmux pane.
Future<bool> answerLooseOn(BuildContext context, Host host, LooseAgent a, {required bool allow}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final k = Tokens.of(context);
  try {
    await answerLooseAgent(host, a, allow: allow);
    if (messenger != null) toastOn(messenger, k, '${allow ? 'Allowed once' : 'Denied'} · ${a.name}', kind: ToastKind.done);
    fleet.feedFor(host).refresh();
    return true;
  } catch (e) {
    if (messenger != null) toastOn(messenger, k, 'Couldn\'t answer ${a.name}: $e', kind: ToastKind.problem);
    return false;
  }
}
