import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'diff_view.dart';
import '../desktop_shell.dart' show detailNavigator;
import '../../data/git_status.dart';
import '../common.dart';
import '../info_bar.dart';
import '../kit.dart';
import '../theme.dart';
import '../status_shape.dart';

/// The short git line under the chat header: branch, +/−, PR #n and its
/// checks. Tap for the folder status sheet.
class GitBar extends StatelessWidget {
  const GitBar({super.key, required this.git, required this.onTap, this.showBranch = true});
  final GitStatus git;
  final VoidCallback onTap;

  /// Off where the header already shows the branch as a chip.
  final bool showBranch;
  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final pr = git.pr;
    final delta = git.added + git.deleted == 0
        ? (git.changedFiles == 0 ? null : '${git.changedFiles} changed')
        : (git.deleted == 0 ? '+${git.added}' : '+${git.added} −${git.deleted}');
    final checks = pr == null || pr.checksTotal == 0
        ? null
        : (
            pr.checksFailed > 0 ? Status.failed : (pr.checksPending > 0 ? Status.idle : Status.working),
            'checks ${pr.checksPassed}/${pr.checksTotal}'
          );
    final ahead = git.upstream != null && git.ahead + git.behind > 0;
    if (!showBranch && !ahead && delta == null && pr == null && checks == null) return const SizedBox.shrink();
    return Semantics(
      button: true,
      hint: 'Show folder status',
      child: InfoBar(
        onTap: onTap,
        child: Row(children: [
            if (showBranch)
              Flexible(
                child: Text(git.branch ?? '?',
                    style: mono(context, size: 11, color: k.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            if (git.upstream != null && git.ahead + git.behind > 0) ...[
              if (showBranch) const SizedBox(width: 6),
              Text([if (git.ahead > 0) '↑${git.ahead}', if (git.behind > 0) '↓${git.behind}'].join(' '),
                  style: mono(context, size: 11)),
            ],
            if (delta != null) ...[
              const SizedBox(width: 8),
              delta.startsWith('+') ? DeltaText(delta) : Text('· $delta', style: mono(context, size: 11)),
            ],
            if (pr != null) ...[
              const SizedBox(width: 6),
              Text('· PR #${pr.number}', style: mono(context, size: 11)),
            ],
            if (checks case (final status, final label)) ...[
              const SizedBox(width: 8),
              StatusShape(status, size: 7, semantics: false),
              const SizedBox(width: 5),
              Text(label, style: mono(context, size: 11, color: status == Status.failed ? k.removed : null)),
            ],
        ]),
      ),
    );
  }
}

/// Files changed in the seat's checkout: status letter, path, line delta. A tap calls [onOpen] with the file's full path (the diff
/// screen), or, with [onPick], [onPick] with its path in the repo (the wide Code tab shows the diff beside the list, and marks the
/// [selected] one). [showHeader] false leaves out its own 'N files changed' line (a section label above says it).
class ChangesCard extends StatelessWidget {
  const ChangesCard({super.key, required this.git, this.onOpen, this.onPick, this.selected, this.showHeader = true});
  final GitStatus git;
  final void Function(String path)? onOpen;
  final void Function(String path)? onPick;
  final String? selected;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final rows = git.changeRows;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        container: true,
        label: 'Changes',
        child: BorderedList(
          header: showHeader
              ? Row(children: [
                  Expanded(
                    child: Text('${rows.length} file${rows.length == 1 ? '' : 's'} changed',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                  DeltaText('+${git.added} −${git.deleted}', size: 12),
                ])
              : null,
          children: [
            for (final (status, path, delta) in rows)
              ColoredBox(
                color: path == selected ? k.fill : Colors.transparent,
                child: RowTile(
                  minHeight: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  onTap: onPick != null ? () => onPick!(path) : (git.root == null || onOpen == null ? null : () => onOpen!('${git.root}/$path')),
                  trailing: DeltaText(delta),
                  child: Row(children: [
                    SizedBox(width: 16, child: Text(status, style: mono(context))),
                    const SizedBox(width: 4),
                    Expanded(child: Text(path, style: mono(context, size: 12, color: k.ink), overflow: TextOverflow.ellipsis)),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The branch's pull request: state, checks, review, and a link.
class PrCard extends StatelessWidget {
  const PrCard({super.key, required this.pr});
  final PullRequest pr;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final muted = TextStyle(fontSize: 12, color: k.muted, height: 1.5);
    String cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1).toLowerCase()}';
    final checks = pr.checksTotal == 0
        ? 'No checks'
        : 'Checks ${pr.checksPassed} of ${pr.checksTotal} passed'
            '${pr.checksPending > 0 ? ' · ${pr.checksPending} running' : ''}'
            '${pr.checksFailed > 0 ? ' · ${pr.checksFailed} failing' : ''}';
    final review = switch (pr.reviewDecision) {
      'APPROVED' => 'Approved',
      'CHANGES_REQUESTED' => 'Changes requested',
      'REVIEW_REQUIRED' => 'Review requested',
      _ => 'No review yet',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        container: true,
        label: 'Pull request',
        child: Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.merge_type, size: 16, color: k.ink),
              const SizedBox(width: 8),
              Expanded(
                child: Text('#${pr.number} ${pr.title}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              Pill(cap(pr.state), tone: statusTone(pr.state)),
            ]),
            const SizedBox(height: 8),
            Text('${pr.checks == 'passing' ? '●' : '○'} $checks',
                style: muted.copyWith(color: pr.checks == 'failing' ? k.accent : null)),
            Text('${pr.reviewDecision == 'APPROVED' ? '●' : '○'} $review', style: muted),
            if (pr.headRef != null && pr.baseRef != null) Text('${pr.headRef} → ${pr.baseRef}', style: muted),
            if (pr.url != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => launchUrl(Uri.parse(pr.url!), mode: LaunchMode.externalApplication),
                iconAlignment: IconAlignment.end,
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('Open pull request', style: TextStyle(fontWeight: FontWeight.w500)),
                style: sheetAction,
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// The folder's uncommitted changes and its branch's PR. These live in a
/// sheet, not the transcript, because git can't say which session made them.
Future<void> showGitSheet(BuildContext context, GitStatus git) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final rows = git.changeRows;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text('Folder status', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Uncommitted changes and the pull request for ${git.branch ?? 'this branch'}. '
                'They belong to the folder, whichever session made them.',
                style: TextStyle(fontSize: 13, color: Tokens.of(ctx).muted),
              ),
              const SizedBox(height: 8),
              if (rows.isNotEmpty)
                ChangesCard(
                  git: git,
                  onOpen: (path) => detailNavigator(context).push(MaterialPageRoute(
                    builder: (_) => DiffScreen(
                      root: git.root!,
                      path: path.substring(git.root!.length + 1),
                      untracked: git.untracked.contains(path.substring(git.root!.length + 1)),
                    ),
                  )),
                ),
              if (git.pr != null) PrCard(pr: git.pr!),
              if (rows.isEmpty && git.pr == null) const Text('No uncommitted changes and no pull request.'),
            ],
          ),
        );
      },
    );
