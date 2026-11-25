import 'package:flutter/material.dart';

import '../app_icon.dart';
import '../kit.dart' show Segmented;
import '../theme.dart';

/// The rig page's actions: New (filled), Message all, Room, Reminders. A null callback greys that one out.
class RigActionSet {
  const RigActionSet({this.onNew, this.onMessageAll, this.onRoom, this.onReminders});
  final VoidCallback? onNew;
  final VoidCallback? onMessageAll;
  final VoidCallback? onRoom;
  final VoidCallback? onReminders;
}

/// A phone's four tiles: New filled, then Message all, Room and Reminders outlined, each an icon over its label.
class RigActionTiles extends StatelessWidget {
  const RigActionTiles(this.actions, {super.key});
  final RigActionSet actions;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    Widget tile(String label, Widget icon, VoidCallback? on, {bool filled = false}) {
      final fg = on == null ? k.faint : (filled ? k.onInk : k.ink);
      return Expanded(
        child: Semantics(
          button: true,
          enabled: on != null,
          label: label,
          onTap: on,
          excludeSemantics: true,
          child: Material(
            color: filled && on != null ? k.ink : Colors.transparent,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kRadius), side: BorderSide(color: filled && on != null ? k.ink : k.border)),
            child: InkWell(
              borderRadius: BorderRadius.circular(kRadius),
              onTap: on,
              child: SizedBox(
                height: 56,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconTheme(data: IconThemeData(color: fg, size: 18), child: icon),
                  const SizedBox(height: 4),
                  Text(label, maxLines: 1, style: TextStyle(fontFamily: fontSans, fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
                ]),
              ),
            ),
          ),
        ),
      );
    }

    return Row(children: [
      tile('New', const Icon(Icons.add), actions.onNew, filled: true),
      const SizedBox(width: 8),
      tile('Message all', const AppIcon(AppIconKind.broadcast), actions.onMessageAll),
      const SizedBox(width: 8),
      tile('Room', const AppIcon(AppIconKind.room), actions.onRoom),
      const SizedBox(width: 8),
      tile('Reminders', const Icon(Icons.notifications_none), actions.onReminders),
    ]);
  }
}

/// The Mac's header buttons: [+ New] [Message all] [Room] [Reminders], 36dp tall.
List<Widget> rigHeaderButtons(BuildContext context, RigActionSet actions) {
  final k = Tokens.of(context);
  Widget button(String label, Widget icon, VoidCallback? on, {bool filled = false}) {
    final style = (filled ? FilledButton.styleFrom : OutlinedButton.styleFrom)(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: const TextStyle(fontFamily: fontSans, fontSize: 13, fontWeight: FontWeight.w600),
    ).merge(compactAction);
    final child = Row(mainAxisSize: MainAxisSize.min, children: [
      IconTheme(data: const IconThemeData(size: 16), child: icon),
      const SizedBox(width: 6),
      Text(label),
    ]);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: filled
          ? FilledButton(onPressed: on, style: style, child: child)
          : OutlinedButton(onPressed: on, style: style.copyWith(side: WidgetStatePropertyAll(BorderSide(color: k.border))), child: child),
    );
  }

  return [
    button('New', const Icon(Icons.add), actions.onNew, filled: true),
    button('Message all', const AppIcon(AppIconKind.broadcast), actions.onMessageAll),
    button('Room', const AppIcon(AppIconKind.room), actions.onRoom),
    button('Reminders', const Icon(Icons.notifications_none), actions.onReminders),
  ];
}

/// List | Tiles, in the rig's header on the Mac: the view on show is [tiles]; the other segment calls [onChange], which
/// puts the other screen in this one's place.
class RigViewSwitch extends StatelessWidget {
  const RigViewSwitch({super.key, required this.tiles, required this.onChange});
  final bool tiles;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Segmented<bool>(
          compact: true,
          values: const [false, true],
          labels: const ['List', 'Tiles'],
          selected: tiles,
          onChanged: (t) => t == tiles ? null : onChange(),
          semanticLabel: 'Rig view',
        ),
      );
}
