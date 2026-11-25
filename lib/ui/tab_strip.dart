import 'package:flutter/material.dart';

import 'theme.dart';

/// Plain text tabs on a hairline, the selected one in ink with an underline: the rig page's views and the agent
/// panel's Info / Files / Images / Artifacts. Scrolls sideways when the tabs don't fit.
class TabStrip<T> extends StatelessWidget {
  const TabStrip({
    super.key,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
    this.semanticLabel,
  });

  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;
  final String? semanticLabel;

  static const height = 40.0;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Semantics(
      label: semanticLabel,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.divider))),
        child: SizedBox(
          height: height,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (var i = 0; i < values.length; i++) _tab(k, labels[i], values[i] == selected, () => onChanged(values[i])),
          ]),
        ),
      ),
    );
  }

  Widget _tab(Tokens k, String label, bool on, VoidCallback tap) => Semantics(
        selected: on,
        button: true,
        inMutuallyExclusiveGroup: true,
        onTap: tap,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: tap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: kEaseOut,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: on ? k.ink : Colors.transparent, width: 2))),
            child: Text(label,
                maxLines: 1,
                style: TextStyle(fontSize: 13, fontWeight: on ? FontWeight.w600 : FontWeight.w400, color: on ? k.ink : k.muted)),
          ),
        ),
      );
}
