import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/git_status.dart';
import '../../data/rig_git.dart';
import '../../main.dart' show AppScope;
import '../../models.dart';
import '../chat/git_cards.dart' show showGitSheet;
import '../host_color.dart' show hostOverline;
import '../rig_screen.dart' show RigStatusLine;
import '../theme.dart';
import '../worktree_chip.dart';

/// The line under a rig's title, the same in every rig view (its page, its tiles, its chat), so nothing moves when you switch:
/// project · host · [branch chip ↑↓ · N changed · PR #n state ↗ ● checks a/b] · N agents. Left-aligned and wrapping. The branch
/// is the checkout of the rig's primary folder, read once per rig ([RigGit]); with no git reading the worktree chip stays.
class RigSubLine extends StatefulWidget {
  const RigSubLine({super.key, required this.rig, required this.seats, required this.projectName});
  final Rig rig;
  final List<Seat> seats;
  final String projectName;

  @override
  State<RigSubLine> createState() => _RigSubLineState();
}

class _RigSubLineState extends State<RigSubLine> {
  RigGit? _feed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final host = AppScope.of(context).active;
    final cwd = RigWithSeats(widget.rig, widget.seats).primaryCwd;
    final next = host == null || cwd == null ? null : RigGit.of(host, cwd);
    if (!identical(next, _feed)) {
      _feed?.unlisten();
      _feed = next?..listen();
    }
  }

  @override
  void didUpdateWidget(RigSubLine old) {
    super.didUpdateWidget(old);
    if (RigWithSeats(old.rig, old.seats).primaryCwd != RigWithSeats(widget.rig, widget.seats).primaryCwd) didChangeDependencies();
  }

  @override
  void dispose() {
    _feed?.unlisten();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final host = AppScope.of(context).active;
    final cwd = RigWithSeats(widget.rig, widget.seats).primaryCwd;
    // Agents that are up, as the Rigs home tally and the tiles count them, so the line reads the same in every view.
    final agents = widget.seats.where((s) => s.isAgent && s.state != SeatState.stopped).length;
    final renamed = host?.rigNames[widget.rig.name] != null;
    final muted = mono(context, size: 12, color: k.muted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 12),
      child: ValueListenableBuilder<GitStatus?>(
        valueListenable: _feed ?? ValueNotifier<GitStatus?>(null),
        builder: (context, git, _) => Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text([widget.projectName, if (renamed) widget.rig.name].join(' · '), style: muted),
          if (host != null) hostOverline(host, muted),
          if (git != null && git.branch != null)
            _GitGroup(git)
          else if (cwd != null)
            WorktreeChip(worktreeName(cwd) ?? 'main'),
          Text('$agents ${agents == 1 ? 'agent' : 'agents'}', style: muted),
          if (widget.rig.status != 'running') RigStatusLine(widget.rig),
        ]),
      ),
    );
  }
}

/// The branch and what is on it: the chip, ↑↓, N changed (these open the folder status sheet), then the PR with its checks
/// as one unit (it opens the PR in the browser). No PR is not an error: nothing is said.
class _GitGroup extends StatelessWidget {
  const _GitGroup(this.git);
  final GitStatus git;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final muted = mono(context, size: 12, color: k.muted);
    final pr = git.pr;
    final ahead = git.upstream != null && git.ahead + git.behind > 0
        ? [if (git.ahead > 0) '↑${git.ahead}', if (git.behind > 0) '↓${git.behind}'].join(' ')
        : (git.upstream == null ? 'not pushed' : null);
    return Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Semantics(
        button: true,
        hint: 'Show folder status',
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadius),
          onTap: () => showGitSheet(context, git),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border.all(color: k.border), borderRadius: BorderRadius.circular(kRadius)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(git.branch!, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12, color: k.ink)),
                ),
              ),
            ),
            if (ahead != null) ...[const SizedBox(width: 10), Text(ahead, style: muted)],
            if (git.changedFiles > 0) ...[const SizedBox(width: 10), Text('${git.changedFiles} changed', style: mono(context, size: 12, color: k.ink))],
          ]),
        ),
      ),
      if (pr != null) _PrLink(pr),
    ]);
  }
}

class _PrLink extends StatelessWidget {
  const _PrLink(this.pr);
  final PullRequest pr;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final state = pr.isDraft && pr.state == 'OPEN' ? 'draft' : pr.state.toLowerCase();
    final open = pr.state == 'OPEN' && !pr.isDraft;
    final failing = pr.checksFailed > 0;
    final showChecks = pr.state == 'OPEN' && pr.checksTotal > 0;
    final dot = failing ? k.removed : (pr.checksPending > 0 ? k.muted : k.added);
    final checks = 'checks ${pr.checksPassed}/${pr.checksTotal}';
    final url = pr.url;
    return Semantics(
      button: true,
      link: true,
      label: 'Pull request ${pr.number}, $state${showChecks ? ', $checks' : ''}',
      onTap: url == null ? null : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadius),
        onTap: url == null ? null : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('PR #${pr.number}', style: mono(context, size: 12, color: k.ink)),
          const SizedBox(width: 6),
          Text(state, style: mono(context, size: 12, color: open ? k.ink : k.muted)),
          const SizedBox(width: 4),
          Icon(Icons.north_east, size: 11, color: k.muted),
          if (showChecks) ...[
            const SizedBox(width: 6),
            DecoratedBox(decoration: BoxDecoration(color: dot, shape: BoxShape.circle), child: const SizedBox(width: 7, height: 7)),
            const SizedBox(width: 5),
            Text(checks, style: mono(context, size: 12, color: failing ? k.removed : k.muted)),
          ],
        ]),
      ),
    );
  }
}
