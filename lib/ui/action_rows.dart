import 'package:flutter/material.dart';

import '../data/fleet.dart' show RigView;
import '../data/host_store.dart' show isDesktop;
import 'desktop_menu.dart';
import 'kit.dart';

/// One row of an action list: icon, label, subtitle, what it does (null: shown but disabled).
typedef ActionRow = (IconData, String, String?, VoidCallback?);

/// How a project or rig row shows its children: the views other than [current], each its own row (Show active only is
/// left out when nothing is active). The sidebar rows have no chevron, so this list is their one control.
List<ActionRow> viewRows(RigView current, bool anyActive, void Function(RigView) onView) => [
      if (current != RigView.all) (Icons.unfold_more_outlined, 'Show all', null, () => onView(RigView.all)),
      if (current != RigView.active && anyActive)
        (Icons.filter_list_outlined, 'Show active only', null, () => onView(RigView.active)),
      if (current != RigView.collapsed) (Icons.unfold_less_outlined, 'Fold', null, () => onView(RigView.collapsed)),
    ];

/// A red action pinned under the rows.
typedef DangerRow = (String, IconData, VoidCallback);

/// What a ⋯ list holds, apart from how it is shown: the sheet shows it, the command palette lists it.
typedef ActionRows = ({List<ActionRow> items, List<DangerRow> danger});

/// The one place a ⋯ list is shown: the Mac's compact popup at the pointer ([showDesktopMenu]), the phone's bottom sheet.
Future<void> showActionRows(BuildContext context, String? title, ActionRows rows) => isDesktop
    ? showDesktopMenu(context, rows)
    : showActionSheet(context, title, [for (final r in rows.items) if (!isMenuBreak(r)) r], danger: rows.danger);
