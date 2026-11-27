import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/host_store.dart' show isDesktop;
import '../../data/outbox.dart';
import 'message_views.dart';
import 'session_pills.dart' show chatGutter;
import '../theme.dart';

/// `/model` aliases Claude Code takes: (alias, label, hint).
const claudeModels = <(String, String, String)>[
  ('default', 'Default', 'The account\'s recommended model'),
  ('opus', 'Opus', 'Most capable, for complex work'),
  ('sonnet', 'Sonnet', 'Fast and capable, for everyday tasks'),
  ('haiku', 'Haiku', 'Fastest, for quick answers'),
  ('opusplan', 'Opus Plan', 'Opus while planning, Sonnet while doing'),
];

/// `/effort` levels: (level, label, hint).
const claudeEfforts = <(String, String, String)>[
  ('auto', 'Auto', 'Let the model decide'),
  ('low', 'Low', 'Quickest answers, least thinking'),
  ('medium', 'Medium', 'A balance of speed and depth'),
  ('high', 'High', 'Thinks longer on hard problems'),
  ('max', 'Max', 'The most thinking the model allows'),
];

/// The message box (board SeatWork): the field with Send in ink (Stop while
/// the agent works and nothing is typed), and under it attach, the model,
/// effort and permission-mode pills.
class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onAttach,
    required this.enabled,
    required this.hint,
    required this.model,
    required this.effort,
    this.mode,
    this.working = false,
    this.onInterrupt,
    this.onModel,
    this.onEffort,
    this.onMode,
  });
  final TextEditingController controller;
  final bool sending;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final String hint;
  final String model;
  final String effort;

  /// The permission mode's label.
  final String? mode;

  /// The agent is mid-turn: what's sent now queues behind it.
  final bool working;

  /// Stops the turn (Esc); the send button turns into it while working with nothing typed.
  final VoidCallback? onInterrupt;

  /// Null where the session can't switch (Codex, not in tmux).
  final VoidCallback? onModel;
  final VoidCallback? onEffort;

  /// Opens the permission sheet; null leaves the mode read-only.
  final VoidCallback? onMode;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    Widget pill(String label, String spoken, VoidCallback? onTap, {IconData? icon}) => Semantics(
          button: onTap != null,
          enabled: enabled,
          label: spoken,
          onTap: enabled ? onTap : null,
          excludeSemantics: true,
          // 30dp to look at, 44dp to hit: the padding above and below is tappable too.
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: enabled ? onTap : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Material(
                color: k.surface,
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius), side: BorderSide(color: k.border)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(kRadius),
                  onTap: enabled ? onTap : null,
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (icon != null) Icon(icon, size: 16, color: k.ink),
                      if (label.isNotEmpty)
                        Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: k.ink)),
                      if (onTap != null && label.isNotEmpty)
                        Text(' ▾', style: TextStyle(fontSize: 10, color: k.muted)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        );
    final iconButton = IconButton.styleFrom(
      foregroundColor: k.onInk,
      backgroundColor: k.ink,
      disabledBackgroundColor: k.border,
      disabledForegroundColor: k.ground,
      fixedSize: const Size(36, 36),
      minimumSize: const Size(36, 36),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
      tapTargetSize: MaterialTapTargetSize.padded,
    );
    return Container(
      color: k.ground,
      child: SafeArea(
        top: false,
        child: Padding(
          // On the Mac its edges are the transcript's and the cards' (chatGutter); the phone keeps 10.
          padding: EdgeInsets.fromLTRB(isDesktop ? chatGutter : 10, 8, isDesktop ? chatGutter : 10, 10),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.fromLTRB(12, 0, 2, 0),
              decoration: BoxDecoration(border: Border.all(color: k.border), borderRadius: BorderRadius.circular(kRadius)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: Focus(
                    // Desktop: Enter sends, Shift+Enter falls through to the field as a newline.
                    onKeyEvent: (_, e) {
                      if (!isDesktop || e is KeyUpEvent) return KeyEventResult.ignored;
                      if (e.logicalKey != LogicalKeyboardKey.enter && e.logicalKey != LogicalKeyboardKey.numpadEnter) {
                        return KeyEventResult.ignored;
                      }
                      // Enter that confirms an IME candidate isn't a send.
                      if (HardwareKeyboard.instance.isShiftPressed || controller.value.composing.isValid) {
                        return KeyEventResult.ignored;
                      }
                      if (e is KeyDownEvent && !sending && enabled && controller.text.trim().isNotEmpty) onSend();
                      return KeyEventResult.handled;
                    },
                    child: TextField(
                      controller: controller,
                      enabled: enabled,
                      minLines: 1,
                      maxLines: 8,
                      textCapitalization: TextCapitalization.sentences,
                      style: const TextStyle(fontSize: 14, height: 1.4),
                      decoration: InputDecoration(
                        hintText: working && enabled ? 'Queue a message for after this turn…' : hint,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        filled: false,
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ),
                ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) {
                    final has = controller.text.trim().isNotEmpty;
                    if (working && !has && onInterrupt != null) {
                      return IconButton.filled(
                        tooltip: 'Stop',
                        onPressed: onInterrupt,
                        style: iconButton,
                        icon: const Icon(Icons.stop_rounded, size: 20),
                      );
                    }
                    return IconButton.filled(
                      tooltip: 'Send',
                      onPressed: sending || !enabled || !has ? null : onSend,
                      style: iconButton,
                      icon: sending
                          ? SizedBox(
                              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: k.onInk))
                          : const Icon(Icons.arrow_upward, size: 18),
                    );
                  },
                ),
              ]),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                Tooltip(
                  message: 'Attach photo or file',
                  child: pill('', 'Attach photos or files', sending ? null : onAttach, icon: Icons.add),
                ),
                const SizedBox(width: 6),
                pill(model, 'Model: $model${onModel != null ? ', change' : ''}', onModel),
                const SizedBox(width: 6),
                pill('effort ${effort.toLowerCase()}', 'Effort: $effort${onEffort != null ? ', change' : ''}', onEffort),
                if (mode != null) ...[
                  const SizedBox(width: 6),
                  pill(mode!.toLowerCase(), 'Permission mode: $mode${onMode != null ? ', change' : ''}', onMode),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A message still in the outbox: retrying on its own, or failed with Retry.
class Unsent extends StatelessWidget {
  const Unsent(this.m, {super.key, required this.onRetry, required this.onDelete});
  final OutMessage m;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final style = TextStyle(fontSize: 12, color: m.failed ? Theme.of(context).colorScheme.error : k.muted);
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      UserBubble(m.text, pending: true),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        Flexible(
          child: Text(
            m.failed ? 'Not sent${m.error == null ? '' : ': ${m.error}'}' : 'Sending… (try ${m.attempts} of ${Outbox.maxAttempts})',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        if (m.failed) TextButton(onPressed: onRetry, child: const Text('Retry')),
        TextButton(onPressed: onDelete, child: const Text('Delete')),
      ]),
    ]);
  }
}
