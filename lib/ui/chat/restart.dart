import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../data/loose_agents.dart';
import '../../main.dart';
import '../../models.dart';
import 'message_views.dart';
import '../common.dart';
import '../hosts_screen.dart';
import '../kit.dart';
import '../theme.dart';
import '../chat_screen.dart' show ChatScreen;

/// What a just-started session shows until its log exists: what to do, and
/// the messages sent so far, which the log will echo once it appears.
class StartingNotice extends StatelessWidget {
  const StartingNotice({super.key, required this.seat, required this.pending, required this.onTerminal});
  final Seat seat;
  final List<String> pending;
  final VoidCallback onTerminal;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return ListView(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      children: [
        for (final p in pending.reversed) UserBubble(p, pending: true),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Starting ${seat.logicalId}…',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
                'The chat fills in once it has said something. Send a first message below, or open the terminal '
                'if it seems stuck: Claude may be asking whether to trust the folder.',
                style: TextStyle(fontSize: 13, color: k.muted, height: 1.4)),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: onTerminal,
              icon: const Icon(Icons.terminal, size: 18),
              label: const Text('Open terminal'),
              style: sheetAction,
            ),
          ]),
        ),
      ],
    );
  }
}

/// Claude sessions in a plain terminal tab can't take input from the app until
/// they've been restarted in tmux.
bool canRestartInTmux(Seat seat) =>
    seat.rigId.isEmpty && seat.isClaude && seat.sessionName == null && seat.resumeToken != null && seat.cwd != null;

/// A spinner and the step the work is on, with Cancel while stopping is safe.
class StepSheet extends StatelessWidget {
  const StepSheet(this.step, {super.key, this.onCancel});
  final ValueListenable<String> step;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 16),
              Flexible(
                child: Semantics(
                  liveRegion: true,
                  child: ValueListenableBuilder(valueListenable: step, builder: (_, text, __) => Text(text)),
                ),
              ),
            ]),
            if (onCancel != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: onCancel,
                style: sheetAction,
                child: const Text('Cancel'),
              ),
            ],
          ]),
        ),
      );
}

/// Shows [StepSheet] until the caller pops it (or, with [cancellable], the person taps Cancel).
Future<void> showStepSheet(BuildContext context, ValueListenable<String> step, {bool cancellable = false}) =>
    showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (ctx) => StepSheet(step, onCancel: cancellable ? () => Navigator.pop(ctx) : null),
    );

/// Says what went wrong. [unreachable] means the host's settings are the place
/// to fix it, so the dialog links there.
Future<void> _showRestartFailed(NavigatorState nav, Host host, Object error,
    {required bool unreachable, String? step}) async {
  final toSettings = await confirmSheet(
    nav.context,
    title: unreachable ? 'Couldn\'t reach ${host.name}' : 'Restart didn\'t finish',
    body: [
      if (step != null) 'Stopped at: $step',
      '$error',
      if (unreachable) 'Nothing was stopped. Check the address, SSH port and key in the host\'s settings.',
    ].join('\n\n'),
    action: unreachable ? 'Host settings' : null,
    cancel: 'Close',
    destructive: false,
  );
  if (toSettings && nav.mounted) {
    unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => HostEditor(host: host))));
  }
}

/// Asks, restarts [seat] in tmux, and opens its chat in place of this screen.
/// A dialog shows each step, because the SSH calls can take several seconds.
Future<void> confirmRestartInTmux(BuildContext context, Seat seat) async {
  final host = AppScope.read(context).active;
  final id = seat.resumeToken, cwd = seat.cwd;
  if (host == null || id == null || cwd == null) return;
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);

  var checking = true;
  unawaited(showStepSheet(nav.context, ValueNotifier('Connecting to ${host.name}…'), cancellable: true)
      .then((_) => checking = false));
  final String? status;
  try {
    status = await looseSessionStatus(host, id);
  } catch (e) {
    if (!nav.mounted || !checking) return;
    nav.pop();
    await _showRestartFailed(nav, host, e, unreachable: true);
    return;
  }
  if (!nav.mounted || !checking) return;
  nav.pop();

  final go = await confirmSheet(
    nav.context,
    title: 'Restart in tmux?',
    body: status == 'idle'
        ? 'This stops the agent and continues the same conversation in tmux, in the same terminal tab, '
            'so you can message it from here. Options it was started with aren\'t kept.'
        : 'This agent may be working right now. Restarting stops it and any running tool, which can leave '
            'that work unfinished. The conversation continues in tmux. Options it was started with aren\'t kept.',
    action: 'Restart',
    destructive: status != 'idle',
  );
  if (!go || !nav.mounted) return;

  String label(RestartStep step) => switch (step) {
        RestartStep.connecting => 'Connecting to ${host.name}…',
        RestartStep.stopping => 'Stopping the agent…',
        RestartStep.starting => 'Starting it in tmux…',
        RestartStep.attaching => 'Switching its terminal tab… If the Mac asks to allow control of the terminal, '
            'allow it there.',
      };
  var step = RestartStep.connecting;
  final shown = ValueNotifier(label(step));
  unawaited(showStepSheet(nav.context, shown));
  try {
    final (:name, :tabLeftBehind) = await restartInTmux(host, sessionId: id, cwd: cwd, onStep: (s) {
      step = s;
      shown.value = label(s);
    });
    if (!nav.mounted) return;
    nav.pop();
    if (tabLeftBehind) {
      toastOn(messenger, k, 'Couldn\'t switch its terminal tab. To watch it there, run: tmux attach -t $name');
    }
    final moved = LooseAgent(
      id: name,
      claudeSessionId: id,
      runtime: 'claude-code',
      cwd: cwd,
      tmuxSession: name,
      transcriptPath: seat.transcriptPath,
    );
    unawaited(nav
        .pushReplacement(MaterialPageRoute<void>(builder: (_) => ChatScreen(rigName: 'no rig', seat: moved.toSeat(), asChat: true))));
  } catch (e) {
    if (!nav.mounted) return;
    nav.pop();
    final unreachable = step == RestartStep.connecting;
    await _showRestartFailed(nav, host, e, unreachable: unreachable, step: unreachable ? null : label(step));
  }
}

/// In place of the composer when the app can only read the session.
class RestartBar extends StatelessWidget {
  const RestartBar({super.key, required this.onRestart});
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Container(
      decoration: BoxDecoration(color: k.ground, border: Border(top: BorderSide(color: k.divider))),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Running in a terminal tab, so this chat is read only.',
                style: TextStyle(fontSize: 13, color: k.muted)),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: onRestart,
              style: sheetAction,
              child: const Text('Restart in tmux'),
            ),
          ]),
        ),
      ),
    );
  }
}
