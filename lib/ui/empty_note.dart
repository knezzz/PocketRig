import 'package:flutter/material.dart';

import 'theme.dart';

/// The two-line empty state: a bold headline and one muted line, centred ('Nothing needs you').
class EmptyNote extends StatelessWidget {
  const EmptyNote(this.headline, this.line, {super.key});
  final String headline;
  final String line;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(headline, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(line, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Tokens.of(context).muted)),
          ]),
        ),
      );
}
