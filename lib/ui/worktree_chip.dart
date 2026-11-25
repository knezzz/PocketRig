import 'package:flutter/material.dart';

import 'app_icon.dart';
import 'theme.dart';

/// The worktree an agent, rig or shell runs in, as a small muted chip: the worktree glyph and its name ('main' for the
/// main checkout). Rig cards always show one; an agent row only when it differs from its rig's; the sidebar only for a
/// worktree that is not main.
class WorktreeChip extends StatelessWidget {
  const WorktreeChip(this.name, {super.key});
  final String name;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Semantics(
      label: 'worktree $name',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 110),
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border.all(color: k.border), borderRadius: BorderRadius.circular(kRadius)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AppIcon(AppIconKind.worktree, size: 11, color: k.muted),
              const SizedBox(width: 3),
              Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 11, color: k.muted))),
            ]),
          ),
        ),
      ),
    );
  }
}
