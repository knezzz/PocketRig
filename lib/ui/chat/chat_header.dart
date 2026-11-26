import 'package:flutter/material.dart';

import '../../data/git_status.dart';
import '../../models.dart';
import '../agent_header.dart';
import '../agent_view_switch.dart';
import '../theme.dart';
import 'git_cards.dart';

/// The chat's AgentHeader, set up once for the single chat page and the rig's paged chat: the title and mono subtitle, the Menu, the
/// branch, the Chat | Terminal switch, then under it the seat tabs ([tabs], when there are several) and the git bar (a repo).
/// [onGit] opens the git sheet.
Widget chatAgentHeader(
  BuildContext context, {
  required Seat? seat,
  required String title,
  required String subtitle,
  required VoidCallback? onMenu,
  required VoidCallback onSwitch,
  required GitStatus? git,
  required void Function(GitStatus git) onGit,
  Widget? tabs,
  List<Widget> extraActions = const [],
}) {
  final repo = git != null && git.isRepo ? git : null;
  return AgentHeader(
    seat: seat,
    title: title,
    subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context)),
    menuTooltip: 'Menu',
    onMenu: onMenu,
    branch: repo?.branch,
    showing: AgentView.chat,
    views: agentViews(seat),
    onSwitch: onSwitch,
    extraActions: extraActions,
    bottom: repo == null && tabs == null
        ? null
        : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (tabs != null) Padding(padding: EdgeInsets.only(bottom: repo != null ? 4 : 0), child: tabs),
            if (repo != null) GitBar(git: repo, showBranch: false, onTap: () => onGit(repo)),
          ]),
  );
}
