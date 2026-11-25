import 'package:flutter/material.dart';

import '../data/fleet.dart';
import '../models.dart';
import 'chat_screen.dart';
import 'common.dart';
import 'desktop_shell.dart';
import 'kit.dart';
import 'theme.dart';
import 'progress_bar.dart' show ContextBar;
import 'status_shape.dart';
import 'worktree_chip.dart';
import 'usage_strip.dart' show contextColor, contextWeight;

export 'project_tally.dart' show RigCountLine, SeatTally, rigCountWords;

/// The look of an agent row: its status shape, name and runtime, and what it's doing. Filled and marked
/// "read only" when you can only watch (no tmux to type into).
/// Left padding of a rig agent's row inside its seat list (see the seat list's own inset).
const double _seatIndent = 34;

class _Leaf extends StatelessWidget {
  const _Leaf({
    required this.runtime,
    required this.title,
    required this.meta,
    required this.state,
    required this.onTap,
    this.readOnly = false,
    this.contextUsed,
    this.tag,
    this.rigName,
    this.rigBadge = true,
    this.flat = false,
    this.said,
    this.rightBar = false,
    this.age,
    this.branch,
  });
  final String? runtime;
  final String title;
  final String meta;
  final SeatState state;
  final VoidCallback onTap;
  final bool readOnly;

  /// Percent of the context window used: a thin bar under the text, no label.
  final double? contextUsed;

  /// Muted text at the end of the name line (its worktree, in a flat list of agents).
  final String? tag;

  /// The rig this agent runs in, muted at the end of its second line: the flat Agents list, whose robot then carries
  /// no rig badge (a loose agent's name says 'no rig'). Null under its rig row, where the badge says it.
  final String? rigName;

  /// The hub badge on the robot when it sits under a rig row; off inside a rig's own card, which says it.
  final bool rigBadge;

  /// Not nested under a rig row: the row starts at the list's own padding.
  final bool flat;

  /// What the agent last said or did ("EDIT lib/ui/kit.dart"), muted, in place of the state words on the second line.
  final String? said;

  /// The worktree chip after the name: set only when it differs from the rig's.
  final String? branch;

  /// The [age], a 64dp context bar and its % at the end of the first line, so bars compare across rows at any width and
  /// the second line keeps the full width; off, the bar is the row's full-width underline.
  final bool rightBar;
  final String? age;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final ctx = contextUsed;
    final status = Status.of(state);
    final row = RowTile(
      minHeight: 44,
      // A rig's agent is indented one step: its robot (with the hub badge) starts under the rig's name.
      padding: EdgeInsets.fromLTRB(flat ? 14 : _seatIndent, 6, 19, 6),
      leading: rigName == null && rigBadge ? StatusIcon.seat(status, runtime: runtime) : StatusIcon.agent(status, runtime: runtime),
      openLabel:
          '$title${rigName == null ? '' : ', rig $rigName'}${tag == null ? '' : ', $tag'}, $meta${ctx == null ? '' : ', context ${ctx.round()} percent used'}${readOnly ? ', read only' : ''}',
      onTap: onTap,
      arrow: !readOnly,
      trailing: readOnly
          ? Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 7),
              decoration: BoxDecoration(
                border: Border.all(color: k.border),
                borderRadius: BorderRadius.circular(kRadius),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.visibility_outlined, size: 12, color: k.muted),
                const SizedBox(width: 4),
                Text('read only', style: TextStyle(fontSize: 11, color: k.muted)),
              ]),
            )
          : null,
      child: SizedBox(
        width: double.infinity,
        child: Stack(clipBehavior: Clip.none, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(
                child: Row(children: [
                  Flexible(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: readOnly ? k.muted : k.ink)),
                  ),
                  if (branch != null) ...[const SizedBox(width: 6), Flexible(child: WorktreeChip(branch!))],
                ]),
              ),
              // The age, a 64dp bar and its % at the end of the first line, so the second line runs the row's full width.
              if (rightBar && !readOnly) ...[
                const SizedBox(width: 8),
                // A fixed column for the age, so every bar starts at one x.
                SizedBox(
                    width: 30,
                    child: Text(age ?? '', textAlign: TextAlign.right, style: mono(context, size: 11, color: k.muted))),
                const SizedBox(width: 8),
                // A seat with no context reading keeps the column's width, so every row's bar and % line up.
                ExcludeSemantics(child: SizedBox(width: 64, child: ctx == null ? null : ContextBar(ctx, height: 3, base: k.muted, label: false))),
                const SizedBox(width: 6),
                ExcludeSemantics(
                  child: SizedBox(
                    width: 30,
                    child: ctx == null ? null : Text('${ctx.round()}%',
                        textAlign: TextAlign.right,
                        style: mono(context, size: 11, color: contextColor(ctx, k))
                            .copyWith(fontWeight: contextWeight(ctx), fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                ),
              ],
              // Right-aligned: every row's worktree ends at the same x, just before the chevron.
              if (tag != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 96),
                  child: Text(tag!, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 11, color: k.muted)),
                ),
            ]),
            if (said != null)
              Text.rich(
                  TextSpan(children: [
                    // 'needs you' stays in front, in the accent, so it survives the line being cut.
                    if (status == Status.needsYou) TextSpan(text: 'needs you · ', style: TextStyle(color: k.accent)),
                    TextSpan(text: said),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: k.muted))
            else
            Text.rich(
                TextSpan(children: [
                  TextSpan(text: meta),
                  // The rig, at the end of the line in muted grey, where a loose agent's line says 'read only' or its runtime.
                  if (rigName case final r?) TextSpan(text: ' · $r', style: TextStyle(color: k.muted)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    color: switch (status) {
                      Status.needsYou => k.accent,
                      Status.working => k.added,
                      Status.shell => k.shell,
                      _ => k.muted,
                    })),
          ]),
          // The graph node's bar, in the row's bottom padding so the row keeps its height.
          if (ctx != null && !rightBar)
            Positioned(
              key: const ValueKey('context-bar'),
              left: 0,
              right: 0,
              bottom: -5,
              child: ContextBar(ctx, height: 3, base: k.muted, label: false),
            ),
        ]),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: readOnly
          ? CustomPaint(
              foregroundPainter: DashedBorder(k.border, radius: kRadius, width: 1),
              child: Material(
                color: k.fill,
                borderRadius: BorderRadius.circular(kRadius),
                clipBehavior: Clip.antiAlias,
                child: row,
              ),
            )
          : Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(kRadius),
              clipBehavior: Clip.antiAlias,
              child: row,
            ),
    );
  }
}

/// A rig's agent: opens its chat (Claude Code) or terminal.
class SeatLeaf extends StatelessWidget {
  const SeatLeaf(
      {super.key, required this.host, required this.rigName, required this.seat, this.tag, this.flat = false, this.rigBadge = true, this.said, this.rightBar = false, this.branch});
  final Host host;
  final String rigName;
  final Seat seat;

  /// See [_Leaf.tag] and [_Leaf.flat].
  final String? tag;
  final bool flat;

  /// See [_Leaf.rigBadge].
  final bool rigBadge;

  /// See [_Leaf.said] and [_Leaf.rightBar].
  final String? said;
  final bool rightBar;

  /// See [_Leaf.branch].
  final String? branch;

  // Rebuilt by the minute tick, so its "Nm ago" ages on a quiet screen.
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: minuteTick, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final s = seat;
    final what = usageLimitLine(s) ??
        switch (s.state) {
          SeatState.needsYou => 'needs you',
          SeatState.working => 'working',
          SeatState.shell => s.jobsLine,
          SeatState.idle => 'idle',
          SeatState.stopped => 'stopped',
        };
    final state = [what, if (s.lastActivityAt != null && !rightBar) ago(s.lastActivityAt)].join(' · ');
    final meta = [
      state,
      if (subagentsOn(host, s) case final subs?) subs,
      if (s.shortModel != null) s.shortModel!,
    ].join(' · ');
    return _Leaf(
      runtime: s.runtime,
      title: s.logicalId,
      meta: meta,
      state: s.state,
      readOnly: s.sessionName == null,
      contextUsed: s.contextUsedPercent,
      tag: tag,
      rigName: flat ? rigName : null,
      rigBadge: rigBadge,
      said: said,
      rightBar: rightBar,
      branch: branch,
      age: s.lastActivityAt == null ? null : ago(s.lastActivityAt),
      flat: flat,
      onTap: () {
        useHost(context, host);
        detailNavigator(context).push(MaterialPageRoute(builder: (_) => seatScreen(rigName, s)));
      },
    );
  }
}
