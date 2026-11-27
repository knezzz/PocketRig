import 'package:flutter/material.dart';

import '../data/host_store.dart' show isDesktop;
import '../models.dart';
import 'agent_view_switch.dart';
import 'progress_bar.dart';
import 'status_shape.dart';
import 'theme.dart';

/// The one header of an agent's chat and terminal, one row: back, the runtime's mark with the state's shape at its
/// corner, the name, the meta line, the branch, then Terminal | Chat, the panels toggle and ⋯. On a narrow window the meta
/// sits under the name. [bottom] is what sits under the row (the chat's git line, the terminal's connection state), in
/// the chat's column; a phone adds the context bar and % under it.
class AgentHeader extends StatelessWidget {
  const AgentHeader({
    super.key,
    required this.seat,
    required this.title,
    required this.subtitle,
    required this.menuTooltip,
    required this.onMenu,
    this.branch,
    this.showing,
    this.onSwitch,
    this.views = const AgentViews(),
    this.extraActions = const [],
    this.bottom,
    this.showBack = true,
  });

  /// Null for a project shell: no mark, no context.
  final Seat? seat;
  final String title;
  final Widget subtitle;
  final String menuTooltip;
  final VoidCallback? onMenu;

  /// The checkout's branch, as a chip after the meta line.
  final String? branch;

  /// The view on screen, with [onSwitch] to go to the other; null hides the switch (an agent that is not Claude).
  final AgentView? showing;
  final VoidCallback? onSwitch;
  final AgentViews views;
  final List<Widget> extraActions;
  final Widget? bottom;

  /// False under another header that has the Back (the rig's, over an enlarged tile's row).
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final s = seat;
    final pct = s?.contextUsedPercent;
    final t = Theme.of(context).textTheme;
    // No status bar above (a desktop window): the header keeps off the window's top edge by 8dp more.
    final topGap = MediaQuery.paddingOf(context).top == 0 ? 8.0 : 0.0;
    // The same icon as every agent row: the runtime's logo in the state colour, no dot.
    final mark = s == null ? null : StatusIcon.agent(Status.of(s.state), runtime: s.runtime);
    // A seat at its usage limit says so under the meta line, in muted red (OpenRig 0.7.22+).
    final limit = s == null ? null : usageLimitLine(s);
    final sub = limit == null
        ? subtitle
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [subtitle, Text(limit, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: limitColor(k)))]);
    final worktree = worktreeName(s?.cwd);
    final chip = branch == null
        ? null
        : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: k.border), borderRadius: BorderRadius.circular(kRadius)),
              child: Text(branch!, style: mono(context, size: 11, color: k.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            // Under the branch: the worktree the seat runs in (nothing in the main checkout).
            if (worktree != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(worktree, style: mono(context, size: 11, color: k.faint), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ]);
    final name = Text(title, style: t.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis);
    return Material(
      color: k.ground,
      child: Container(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.border))),
        padding: EdgeInsets.fromLTRB(12, 4 + topGap, 12, 8),
        child: SafeArea(
          bottom: false,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            LayoutBuilder(builder: (context, box) {
              final wide = box.maxWidth >= 640;
              return Row(children: [
                if (showBack && Navigator.of(context).canPop())
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.chevron_left, size: 26),
                  ),
                if (mark != null) ...[mark, const SizedBox(width: 8)],
                Expanded(
                  child: Semantics(
                    header: true,
                    child: wide
                        ? Row(children: [
                            Flexible(flex: 0, child: name),
                            const SizedBox(width: 12),
                            Expanded(child: sub),
                            if (chip != null) ...[const SizedBox(width: 8), Flexible(flex: 0, child: chip)],
                          ])
                        : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            name,
                            sub,
                          ]),
                  ),
                ),
                const SizedBox(width: 8),
                // The extra actions (the panels toggle) sit left of the switch, so the switch is at one x on every agent screen.
                ...extraActions,
                if (showing != null && onSwitch != null)
                  Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: AgentViewSwitch(showing: showing!, views: views, onChanged: (_) => onSwitch!())),
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: IconButton(tooltip: menuTooltip, onPressed: onMenu, icon: const Icon(Icons.more_horiz, size: 24)),
                ),
              ]);
            }),
            if (bottom != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                // Its edges are the chat cards' edges: the header's own 12 and 8 more, the list's 20.
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: bottom),
              ),
            if (s != null && !isDesktop && pct != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Row(children: [
                  Expanded(child: ContextBar(pct, height: 6)),
                  const SizedBox(width: 8),
                  Text('${pct.round()}%', style: mono(context, size: 11, color: k.muted)),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}
