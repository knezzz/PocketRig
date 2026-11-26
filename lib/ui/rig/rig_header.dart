import 'package:flutter/material.dart';

import '../app_icon.dart';
import '../../models.dart';
import '../kit.dart' show Segmented;
import '../rig_screen.dart' show RigScreen;
import '../tiles_screen.dart' show TilesScreen;
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

/// The two ways to see a rig on the Mac: its page (List) and its agents as live terminals (Tiles). An agent's chat is
/// reached per agent.
enum RigMode { tiles, rig }

/// List | Tiles, in the header of each of the two on the Mac: [current] is on show; the other segment puts that screen in
/// this one's place (replaced, not pushed), so Back from either leaves the rig.
class RigViewSwitch extends StatelessWidget {
  const RigViewSwitch({super.key, required this.current, required this.rig, required this.projectName});
  final RigMode current;
  final RigWithSeats rig;
  final String projectName;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Segmented<RigMode>(
          compact: true,
          values: RigMode.values.reversed.toList(),
          labels: const ['List', 'Tiles'],
          selected: current,
          onChanged: (v) {
            if (v == current) return;
            Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
                builder: (_) => v == RigMode.tiles
                    ? TilesScreen(rig: rig.rig, seats: rig.seats, projectName: projectName)
                    : RigScreen(rig: rig.rig, projectName: projectName)));
          },
          semanticLabel: 'Rig view',
        ),
      );
}
