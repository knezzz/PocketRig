import 'package:flutter/material.dart';

import '../../models.dart';
import '../action_rows.dart';
import '../app_icon.dart';
import '../new_session_sheet.dart' show startAgentInFolder;
import '../rig_screen.dart' show RigScreen;
import '../theme.dart';
import 'rig_actions.dart';
import 'rig_header.dart';
import 'rig_room.dart' show RigRoomScreen, RemindersScreen, broadcastToRig;

/// The rig's own actions, the same on every rig view (its page, its tiles, an agent's chat): + New, Message all, Room, Reminders.
RigActionSet rigActionSet(BuildContext context, Rig rig, List<Seat> seats) {
  final cwd = RigWithSeats(rig, seats).primaryCwd;
  return RigActionSet(
    onNew: cwd == null ? null : () => startAgentInFolder(context, cwd),
    onMessageAll: rig.status == 'stopped' ? null : () => broadcastToRig(context, rig),
    onRoom: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RigRoomScreen(rig: rig))),
    onReminders: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RemindersScreen(rig: rig, seats: seats))),
  );
}

/// The rig's fixed row of actions, for a view's header: on a window wide enough [+ New] [Message all] [Room] [Reminders]
/// [Rig details] and the ⋯ with the rig's options; narrower (a phone) only the ⋯, whose sheet has those same actions above the
/// options. [onRigPage]: this is the rig page, so Rig details is shown selected. [onDeleted] lets the view leave when the rig goes.
List<Widget> rigBarActions(
  BuildContext context, {
  required Rig rig,
  required List<Seat> seats,
  required String projectName,
  required bool wide,
  bool onRigPage = false,
  VoidCallback? onDeleted,
}) {
  final set = rigActionSet(context, rig, seats);
  void details() => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => RigScreen(rig: rig, projectName: projectName)));
  void more() {
    final rows = rigActionRows(context, rig, seats, projectName: projectName, onDeleted: onDeleted);
    if (wide) {
      showActionRows(context, rig.name, rows);
      return;
    }
    final own = <ActionRow>[
      (Icons.add, 'New', null, set.onNew),
      (Icons.campaign_outlined, 'Message all', null, set.onMessageAll),
      (Icons.forum_outlined, 'Room', null, set.onRoom),
      (Icons.notifications_none, 'Reminders', null, set.onReminders),
      if (!onRigPage) (Icons.info_outline, 'Rig details', null, details),
    ];
    showActionRows(context, rig.name, (items: [...own, ...rows.items], danger: rows.danger));
  }

  return [
    if (wide) ...[
      ...rigHeaderButtons(context, set),
      RigDetailsButton(rig: rig, projectName: projectName, selected: onRigPage),
    ],
    IconButton(tooltip: 'Rig options', icon: const Icon(Icons.more_horiz), onPressed: more),
  ];
}

/// The rig's bar above an agent's chat on the Mac: the rig's icon and name, then the same fixed row as the rig's page and tiles.
class RigBar extends StatelessWidget {
  const RigBar({super.key, required this.rig, required this.seats, required this.projectName});
  final Rig rig;
  final List<Seat> seats;
  final String projectName;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Material(
      color: k.ground,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.border))),
        child: Row(children: [
          AppIcon(AppIconKind.rig, size: 18, color: k.accent),
          const SizedBox(width: 8),
          Flexible(child: Text(rig.name, style: Theme.of(context).textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const Spacer(),
          ...rigBarActions(context,
              rig: rig, seats: seats, projectName: projectName, wide: true, onDeleted: () => Navigator.of(context).maybePop()),
        ]),
      ),
    );
  }
}
