import 'package:flutter/material.dart';

import '../app_icon.dart';
import '../../models.dart';

import 'rig_host.dart' show RigHost, RigMode;
import '../theme.dart';

/// The rig page's actions: New (filled), Message all, Room, Reminders. A null callback greys that one out.
class RigActionSet {
  const RigActionSet({this.onNew, this.onMessageAll, this.onRoom, this.onReminders});
  final VoidCallback? onNew;
  final VoidCallback? onMessageAll;
  final VoidCallback? onRoom;
  final VoidCallback? onReminders;
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

/// 'Rig details' in a rig view's header on the Mac, a toggle: the rig's page (Agents, Messages, Progress, Code) when it is not
/// on show, the tiles when it is ([selected]). In the rig's host that is a switch inside one screen (the tiles stay alive); from
/// an agent's chat, which is no host, it replaces the chat with the rig's host on the page (Back leaves the rig).
class RigDetailsButton extends StatelessWidget {
  const RigDetailsButton({super.key, required this.rig, required this.projectName, this.selected = false});
  final Rig rig;
  final String projectName;
  final bool selected;

  @override
  Widget build(BuildContext context) => _RigViewButton(
      label: 'Rig details',
      icon: Icons.info_outline,
      selected: selected,
      onPressed: () {
        final host = RigHost.maybeOf(context);
        if (host != null) return host.toggle();
        Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: (_) => RigHost(rig: rig, projectName: projectName, initial: RigMode.rig)));
      });
}

class _RigViewButton extends StatelessWidget {
  const _RigViewButton({required this.label, required this.icon, required this.onPressed, this.selected = false});
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final style = OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: const TextStyle(fontFamily: fontSans, fontSize: 13, fontWeight: FontWeight.w600),
      backgroundColor: selected ? k.accent.withValues(alpha: .14) : null,
      foregroundColor: selected ? k.accent : null,
    ).merge(compactAction);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        selected: selected,
        child: OutlinedButton(
          onPressed: onPressed,
          style: style.copyWith(side: WidgetStatePropertyAll(BorderSide(color: selected ? k.accent : k.border, width: selected ? 1.5 : 1))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16),
            const SizedBox(width: 6),
            Text(label),
          ]),
        ),
      ),
    );
  }
}
