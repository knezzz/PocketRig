import 'package:flutter/material.dart';

import 'theme.dart';

/// The app's one switch row: a title, an optional muted line under it, and the switch. [inset] false drops the side
/// padding (a row inside a step or a form that has its own).
class SwitchRow extends StatelessWidget {
  const SwitchRow(this.title, {super.key, this.subtitle, required this.value, required this.onChanged, this.inset = true});
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool inset;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: inset ? null : EdgeInsets.zero,
        value: value,
        onChanged: onChanged,
        title: Text(title, style: const TextStyle(fontSize: 15)),
        subtitle: subtitle == null ? null : Text(subtitle!, style: TextStyle(fontSize: 12, color: Tokens.of(context).muted)),
      );
}
