import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/host_store.dart' show isDesktop;
import '../answer_bar.dart';
import '../permission_card.dart';
import '../theme.dart';
import 'session_pills.dart' show chatGutter;

/// The keys that answer a pending permission on desktop: ⌘↵ (Ctrl+↵ off a
/// Mac) allows once, Esc denies.
String get permissionKeysHint =>
    defaultTargetPlatform == TargetPlatform.macOS ? '⌘↵ allow · esc deny' : 'ctrl+↵ allow · esc deny';

/// A pending permission docked where the composer was (boards Seat and
/// Desktop): "PERMISSION · Bash", the command, then the one [AnswerBar].
/// On desktop it takes focus so ⌘↵ / Ctrl+↵ allows and Esc denies, and says so.
class PermissionDock extends StatelessWidget {
  const PermissionDock({
    super.key,
    required this.who,
    required this.ask,
    required this.question,
    required this.onAllow,
    required this.onDeny,
    this.note,
    this.mode,
    this.onAlways,
    this.onDenyWithNote,
    this.onAllowAuto,
    this.desktop,
  });
  /// The seat's name, for the band: "lead wants to run".
  final String who;
  final PermissionAsk ask;

  /// "Allow lead to run this command?", read out for screen readers.
  final String question;

  /// What the agent said the call is for (a Bash description).
  final String? note;

  /// The seat's permission mode label, e.g. "Ask".
  final String? mode;
  final VoidCallback onAllow;
  final VoidCallback onDeny;
  final VoidCallback? onAlways;
  final VoidCallback? onDenyWithNote;
  final VoidCallback? onAllowAuto;

  /// Keyboard shortcuts and their hint; defaults to [isDesktop].
  final bool? desktop;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final keys = desktop ?? isDesktop;
    final bar = AnswerBar(
      onAllow: onAllow,
      onDeny: onDeny,
      onAlways: onAlways,
      alwaysScope: ask.alwaysScope,
      onDenyWithNote: onDenyWithNote,
      onAllowAuto: onAllowAuto,
    );
    final card = PermissionCard(
      who: who,
      ask: ask,
      note: note,
      semanticsLabel: 'Permission request: $question',
      margin: const EdgeInsets.fromLTRB(chatGutter, 6, chatGutter, 10),
      trailing: mode == null ? null : Text('mode: ${mode!.toLowerCase()}', style: mono(context, size: 11)),
      answer: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        bar,
        if (keys)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(permissionKeysHint, textAlign: TextAlign.end, style: TextStyle(fontSize: 12, color: k.muted)),
          ),
      ]),
    );
    if (!keys) return SafeArea(top: false, child: card);
    return SafeArea(
      top: false,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): onAllow,
          const SingleActivator(LogicalKeyboardKey.enter, control: true): onAllow,
          const SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true): onAllow,
          const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true): onAllow,
          const SingleActivator(LogicalKeyboardKey.escape): onDeny,
        },
        child: Focus(autofocus: true, child: card),
      ),
    );
  }
}
