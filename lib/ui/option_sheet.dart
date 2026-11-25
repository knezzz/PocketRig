import 'package:flutter/material.dart';

import 'kit.dart' show RowTile;
import 'theme.dart';

/// A pick-one list in a bottom sheet: one sheet for every "choose one of these" (the model, the effort, the appearance, a
/// spec field). Each row says what it is, with an optional hint under it; the current one is checked, for the eye and for a
/// screen reader, which is told which one is chosen. Pops the picked value, or with [wrap] a one-field record `(value,)`, so a
/// null value can be told from dismissing the sheet.
class OptionSheet<T> extends StatelessWidget {
  const OptionSheet(
      {super.key, required this.title, required this.options, required this.current, this.note, this.wrap = false});
  final String title;
  final List<(T value, String label, String? hint)> options;
  final T current;
  final String? note;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(note!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          for (final (value, label, hint) in options)
            Semantics(
              inMutuallyExclusiveGroup: true,
              checked: value == current,
              child: RowTile(
                minHeight: hint == null ? 48 : 52,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                onTap: () => Navigator.pop(context, wrap ? (value,) : value),
                trailing: value == current ? Icon(Icons.check, size: 20, color: k.ink) : null,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  if (hint != null) Text(hint, style: TextStyle(fontSize: 12, color: k.muted)),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}
