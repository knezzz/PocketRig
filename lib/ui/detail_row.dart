import 'package:flutter/material.dart';

import 'kit.dart' show Chevron;
import 'theme.dart';

/// One row of a detail card: a muted label in a fixed column, then its value; or with no value, an action row (an optional
/// leading icon and the label). A tappable row is one InkWell across the card's full width, 48 tall at least, with a ›
/// ([external]: ↗, it leaves the app) in a fixed column at its end; the others are 40. The seat sheet, the details card and
/// the loose agent's page all show their facts with this.
class DetailRow extends StatelessWidget {
  const DetailRow(this.label, this.value,
      {super.key, this.onTap, this.external = false, this.icon, this.padding = const EdgeInsets.fromLTRB(14, 6, 6, 6)});
  final String label;
  final Widget? value;

  /// An action row's leading icon: 20 dp muted, 12 dp gap, like the app's other card action rows.
  final IconData? icon;
  final VoidCallback? onTap;
  final bool external;
  final EdgeInsets padding;

  /// The label column.
  static const labelWidth = 104.0;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: onTap == null ? 40 : 48),
      child: Padding(
        padding: padding,
        child: Row(crossAxisAlignment: value == null ? CrossAxisAlignment.center : CrossAxisAlignment.start, children: [
          if (icon != null) ...[Icon(icon, size: 20, color: k.muted), const SizedBox(width: 12)],
          if (value == null)
            Expanded(child: Text(label, style: const TextStyle(fontSize: 14)))
          else ...[
            SizedBox(width: labelWidth, child: Text(label, style: TextStyle(fontSize: 13, color: k.muted))),
            Expanded(child: value!),
          ],
          SizedBox(
            width: 28,
            child: onTap == null
                ? null
                : external
                    ? Icon(Icons.north_east, size: 16, color: k.faint)
                    : const Chevron(),
          ),
        ]),
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}
