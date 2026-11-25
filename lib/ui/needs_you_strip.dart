import 'package:flutter/material.dart';

import 'kit.dart' show navMouse;
import 'status_shape.dart';
import 'theme.dart';

/// The one line a terminal shows when its agent is waiting for you: the answer buttons are not in the terminal, they are
/// in the Chat, so this says so and goes there. Tinted with the accent so it is not missed; a finger gets 44dp.
class NeedsYouStrip extends StatelessWidget {
  const NeedsYouStrip({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final h = navMouse() ? 36.0 : 44.0;
    return Semantics(
      button: true,
      label: 'Needs you. Answer in Chat',
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: Color.alphaBlend(k.accent.withValues(alpha: .12), k.ground),
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: h,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: k.border))),
            child: Row(children: [
              const StatusShape(Status.needsYou, size: 10, semantics: false),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Needs you · Answer in Chat',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: k.ink)),
              ),
              Text('›', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: k.accent, height: 1)),
            ]),
          ),
        ),
      ),
    );
  }
}
