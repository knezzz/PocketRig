import 'package:flutter/material.dart';

import 'kit.dart' show navMouse;
import 'theme.dart';

/// The one way to answer a permission request, the same on every screen (Inbox, chat, details, banner): three equal
/// buttons, Deny · Always · Allow once (filled), 36 tall with a mouse and 48 on touch; the scope of Always under them;
/// then one row of small text actions ("Deny & tell it instead…", "Allow & switch to auto", and the caller's [extras]
/// such as Terminal and Open in chat). A null callback hides that answer.
class AnswerBar extends StatelessWidget {
  const AnswerBar({
    super.key,
    required this.onAllow,
    required this.onDeny,
    this.onAlways,
    this.alwaysScope,
    this.onDenyWithNote,
    this.onAllowAuto,
    this.extras = const [],
    this.busy = false,
    this.compact = false,
  });

  final VoidCallback onAllow;
  final VoidCallback onDeny;
  final VoidCallback? onAlways;

  /// What "Always" covers, e.g. `npm run`; said under the buttons.
  final String? alwaysScope;
  final VoidCallback? onDenyWithNote;
  final VoidCallback? onAllowAuto;

  /// More small text actions on the same row (label, tap).
  final List<(String, VoidCallback?)> extras;

  /// Disables the buttons while an answer is on its way.
  final bool busy;

  /// Smaller buttons for list rows (Deny · Allow only).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final text = TextStyle(fontFamily: fontSans, fontSize: compact ? 13 : 14, fontWeight: FontWeight.w600);
    final mouse = navMouse();
    final size = ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(0, mouse ? 36 : 48)));
    Widget outlined(String label, VoidCallback? on) => OutlinedButton(
          onPressed: busy ? null : on,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            textStyle: text,
            side: BorderSide(color: k.border),
          ).merge(compact ? compactAction : size),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        );
    final allow = FilledButton(
      onPressed: busy ? null : onAllow,
      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10), textStyle: text)
          .merge(compact ? compactAction : size),
      child: Text(compact ? 'Allow' : 'Allow once'),
    );
    if (compact) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        outlined('Deny', onDeny),
        const SizedBox(width: 6),
        allow,
      ]);
    }
    final links = [
      if (onDenyWithNote != null) ('Deny & tell it instead…', onDenyWithNote),
      if (onAllowAuto != null) ('Allow & switch to auto', onAllowAuto),
      ...extras,
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(child: outlined('Deny', onDeny)),
        if (onAlways != null) ...[const SizedBox(width: 8), Expanded(child: outlined('Always', onAlways))],
        const SizedBox(width: 8),
        Expanded(child: allow),
      ]),
      if (onAlways != null && alwaysScope != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Always allows “$alwaysScope”', style: TextStyle(fontSize: 12, color: k.muted)),
        ),
      if (links.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(spacing: 12, children: [for (final (label, on) in links) _Link(label, busy ? null : on)]),
        ),
    ]);
  }
}

class _Link extends StatelessWidget {
  const _Link(this.label, this.onTap);
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          foregroundColor: Tokens.of(context).muted,
          textStyle: const TextStyle(
              fontFamily: fontSans, fontSize: 12, fontWeight: FontWeight.w500, decoration: TextDecoration.underline)).merge(compactAction),
        child: Text(label),
      );
}
