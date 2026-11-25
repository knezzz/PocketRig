import 'package:flutter/material.dart';

import 'kit.dart';
import 'theme.dart';

/// What a check row says: passed, a problem, not run (skipped, or not known), or still to do.
enum CheckState {
  ok(Icons.check_circle, 'passed'),
  bad(Icons.error_outline, 'problem'),
  off(Icons.remove_circle_outline, 'not run'),
  todo(Icons.radio_button_unchecked, 'to do');

  const CheckState(this.icon, this.word);
  final IconData icon;

  /// How a screen reader says it.
  final String word;

  Color color(Tokens k) => switch (this) {
        CheckState.ok => k.added,
        CheckState.bad => k.removed,
        CheckState.off => k.faint,
        CheckState.todo => k.muted,
      };
}

/// How a [CheckRow] lays out its text.
enum CheckLayout {
  /// A bare line: the mark and the text (a checklist).
  line,

  /// The text, with its detail under it (the launch checks).
  stacked,

  /// A tappable tile: the label, and its detail on a second line (Health).
  tile,
}

/// The one check mark: a state's icon in its color.
class CheckMark extends StatelessWidget {
  const CheckMark(this.state, {super.key, this.size = 18});
  final CheckState state;
  final double size;
  @override
  Widget build(BuildContext context) =>
      ExcludeSemantics(child: Icon(state.icon, size: size, color: state.color(Tokens.of(context))));
}

/// A checked thing: its [state]'s mark, its [text] and an optional [detail]. [struck] crosses the text out (done
/// items of a checklist); [indent] nests a line; a [CheckLayout.tile] takes an [onTap] and shows a ⌄.
class CheckRow extends StatelessWidget {
  const CheckRow(this.state, this.text,
      {super.key,
      this.detail,
      this.layout = CheckLayout.line,
      this.indent = 0,
      this.struck = false,
      this.onTap,
      this.word,
      this.note});
  final CheckState state;
  final String text;
  final String? detail;
  final CheckLayout layout;
  final double indent;
  final bool struck;
  final VoidCallback? onTap;

  /// A [CheckLayout.line]'s count after the text, in red ("2 blocked" on a parent of blocked steps).
  final String? note;

  /// What a screen reader says for the state, when [state]'s own word is too coarse ("in progress" vs "to do").
  final String? word;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final spoken = '$text: ${word ?? state.word}${note == null ? '' : ', $note'}${detail == null || detail!.isEmpty ? '' : ', $detail'}';
    final bad = state == CheckState.bad;
    switch (layout) {
      case CheckLayout.tile:
        return RowTile(
          minHeight: 48,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          onTap: onTap,
          openLabel: spoken,
          trailing: onTap == null ? null : Icon(Icons.expand_more, size: 16, color: k.faint),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: CheckMark(state)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(text, style: const TextStyle(fontSize: 14)),
                if (detail != null && detail!.isNotEmpty && detail != '—')
                  Text(detail!, style: TextStyle(fontSize: 12, color: bad ? k.removed : k.muted)),
              ]),
            ),
          ]),
        );
      case CheckLayout.stacked:
        return Semantics(
          label: spoken,
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CheckMark(state),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(text, style: const TextStyle(fontSize: 14)),
                  if (detail != null && detail!.isNotEmpty)
                    Text(detail!, style: TextStyle(fontSize: 12, color: bad ? k.removed : k.muted)),
                ]),
              ),
            ]),
          ),
        );
      case CheckLayout.line:
        return Semantics(
          label: spoken,
          excludeSemantics: true,
          child: Padding(
            padding: EdgeInsets.only(left: indent, top: 3, bottom: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CheckMark(state, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: text),
                    if (note != null) TextSpan(text: ' · $note', style: TextStyle(color: k.removed)),
                  ]),
                  style: TextStyle(
                      fontSize: 13,
                      // A blocked step reads red in words, not only in its small icon.
                      color: bad ? k.removed : (struck ? k.muted : k.ink),
                      decoration: struck ? TextDecoration.lineThrough : null),
                ),
              ),
            ]),
          ),
        );
    }
  }
}
