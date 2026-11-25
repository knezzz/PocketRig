import 'package:flutter/material.dart';

import '../data/needs_you.dart' show PermissionAsk;
import 'theme.dart';

export '../data/needs_you.dart' show PermissionAsk;

/// "lead wants to run", "lead wants to use Edit": the first line of every permission request.
String permissionWants(String who, PermissionAsk ask) => ask.tool == 'Bash'
    ? '$who wants to run'
    : ask.tool == null
        ? '$who wants to use a tool'
        : '$who wants to use ${ask.tool}';

/// The command (or tool call) a request is about: the dark code block every permission request shows. [maxLines] clips it
/// to a few lines (the banner); without it a long command scrolls inside [maxHeight].
class PermissionCode extends StatelessWidget {
  const PermissionCode(this.text, {super.key, this.maxHeight = 140, this.maxLines, this.mono12 = true});
  final String text;
  final double maxHeight;
  final int? maxLines;
  final bool mono12;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final style = mono12 ? mono(context, size: 12, color: k.termFg) : TextStyle(fontSize: 14, height: 1.4, color: k.termFg);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: k.termBg, borderRadius: BorderRadius.circular(kRadius)),
      child: maxLines != null
          ? Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style)
          : ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(child: Text(text, style: style)),
            ),
    );
  }
}

/// One permission request: a tinted band ("lead wants to run" and the tool), the command in a dark block, then [answer]
/// (the shared answer bar). [compact] is for a list or a detail pane: less padding and a shorter command.
class PermissionCard extends StatelessWidget {
  const PermissionCard({
    super.key,
    required this.who,
    required this.ask,
    required this.answer,
    this.note,
    this.trailing,
    this.compact = false,
    this.margin = EdgeInsets.zero,
    this.semanticsLabel,
  });
  final String who;
  final PermissionAsk ask;
  final Widget answer;

  /// What the agent said the call is for (a Bash description).
  final String? note;

  /// At the band's right (the age, the seat's mode).
  final Widget? trailing;
  final bool compact;
  final EdgeInsets margin;

  /// What a screen reader says for the card; defaults to the band's line.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final pad = compact ? 10.0 : 14.0;
    final wants = permissionWants(who, ask);
    return Semantics(
      container: true,
      label: semanticsLabel ?? 'Permission request: $wants',
      child: Container(
        margin: margin,
        decoration: BoxDecoration(
          color: k.surface,
          border: Border.all(color: k.accent),
          borderRadius: BorderRadius.circular(kRadius),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            color: Color.alphaBlend(k.accent.withValues(alpha: .10), k.surface),
            padding: EdgeInsets.symmetric(horizontal: pad, vertical: compact ? 8 : 10),
            child: Row(children: [
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: wants, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    if (ask.tool != null && ask.tool != 'Bash')
                      TextSpan(text: '  ${ask.tool!.toUpperCase()}', style: mono(context, size: 11, color: k.muted)),
                  ]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ]),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(pad, compact ? 8 : 12, pad, compact ? 8 : 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (note != null && note!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(note!,
                      style: TextStyle(fontSize: 12, color: k.muted), maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
              PermissionCode(ask.detail, maxHeight: compact ? 90 : 140),
              SizedBox(height: compact ? 8 : 12),
              answer,
            ]),
          ),
        ]),
      ),
    );
  }
}
