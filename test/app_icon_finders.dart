import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/app_icon.dart';
import 'package:pocket_rig/ui/status_shape.dart';

/// An [AppIcon] of [kind] (the app's own rig, folder, agent, subagent and shell icons).
Finder appIcon(AppIconKind kind, {bool skipOffstage = true}) =>
    find.byWidgetPredicate((w) => w is AppIcon && w.kind == kind, skipOffstage: skipOffstage);

/// An agent's [StatusIcon] (its runtime's logo in the state colour), not a subagent's, a shell's or a rig's.
Finder agentIcon({bool skipOffstage = true}) => find.byWidgetPredicate(
    (w) => w is StatusIcon && w.kind == StatusKind.agent && w.icon == AppIconKind.agent,
    skipOffstage: skipOffstage);
