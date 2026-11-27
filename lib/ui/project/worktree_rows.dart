import 'package:flutter/material.dart';
import '../../data/git_status.dart';
import '../answer_bar.dart';
import '../kit.dart';
import '../theme.dart';

/// A worktree card's header, in the section-header style: its name and a hairline, "branch · push state", the PR
/// line and its ⋯ actions.
class WorktreeHead extends StatelessWidget {
  const WorktreeHead({
    super.key,
    required this.title,
    required this.main,
    this.worktree,
    this.pr,
    this.busy = false,
    this.onOpen,
    this.onMenu,
    this.onRemove,
  });
  final String title;
  final bool main;
  final Worktree? worktree;
  final PullRequest? pr;
  final bool busy;
  final VoidCallback? onOpen;
  final VoidCallback? onMenu;

  /// A worktree git lists but whose folder is gone: greyed, 'missing', and this clears it from the list (git worktree prune)
  /// in place of the ⋯.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final w = worktree;
    final gone = w?.missing ?? false;
    final pr = this.pr;
    // A section header, not a row: no fill, the name then a hairline; the ⋯ stays at the right.
    return Semantics(
      header: true,
      child: InkWell(
        onTap: gone ? null : onOpen,
        onLongPress: gone ? null : onMenu,
        onSecondaryTap: gone ? null : onMenu,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
            // Stretched, so the hairline fills up to the ⋯ in the rig rows' right column.
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              GroupHeader(
                icon: main ? Icons.home_outlined : Icons.call_split,
                title: title,
                gone: gone,
                trailing: gone
                    // Aligned right with the ⋯ column of the rows below.
                    ? TextButton(
                        onPressed: busy ? null : onRemove,
                        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), foregroundColor: k.muted).merge(compactAction),
                        child: const Text('Remove from list'))
                    : busy
                    ? const SizedBox(
                        width: 48,
                        height: 44,
                        child: Center(
                            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))))
                    : onMenu != null
                        ? IconButton(
                            tooltip: 'Worktree actions',
                            icon: const Icon(Icons.more_horiz, size: 20),
                            onPressed: onMenu,
                          )
                        : null,
              ),
              if (w != null)
                Padding(
                  padding: const EdgeInsets.only(left: 20, top: 2),
                  child: Text(
                      gone
                          ? 'missing: its folder is gone (${w.branch ?? 'detached HEAD'})'
                          : [
                              w.branch ?? 'detached HEAD',
                              if (w.pushState.isNotEmpty) w.pushState,
                              if (pr == null) 'no PR',
                            ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(context, size: 11, color: gone ? goneColor(k) : null)),
                ),
              if (pr != null)
                Padding(
                  padding: const EdgeInsets.only(left: 20, top: 2),
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: 'PR #${pr.number}', style: mono(context, size: 11, color: k.ink)),
                      TextSpan(
                        text: '  ${pr.checksFailed > 0 ? '${pr.checksFailed} failing · ' : ''}${prLine(pr)}',
                        style: TextStyle(fontSize: 11, color: pr.checksFailed > 0 ? k.removed : k.muted),
                      ),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A row in Needs you: who and what it asks; a permission is answered here (Deny · Allow), a question opens
/// the seat (Answer).
class NeedsRow extends StatelessWidget {
  const NeedsRow({
    super.key,
    required this.title,
    required this.detail,
    required this.code,
    required this.onOpen,
    required this.permission,
    required this.busy,
    required this.onAllow,
    required this.onDeny,
  });
  final String title;
  final String detail;
  final bool code;

  /// Null: nothing to open, so no tap and no Answer.
  final VoidCallback? onOpen;
  final bool permission;
  final bool busy;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return RowTile(
      minHeight: 56,
      padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
      onTap: onOpen,
      trailing: permission
          ? AnswerBar(compact: true, busy: busy, onAllow: onAllow, onDeny: onDeny)
          : onOpen == null
              ? null
              : OutlinedButton(
                  onPressed: onOpen,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    side: BorderSide(color: k.border)).merge(compactAction),
                  child: const Text('Answer'),
                ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(detail,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: code ? mono(context, size: 12) : TextStyle(fontSize: 12, color: k.muted)),
      ]),
    );
  }
}

/// A pull request's checks at a glance: failed, still running, or passed.
class ChecksIcon extends StatelessWidget {
  const ChecksIcon(this.pr, {super.key});
  final PullRequest pr;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final (IconData icon, Color color, String label) = pr.checksFailed > 0
        ? (Icons.cancel_outlined, k.removed, 'Checks failing')
        : pr.checksPending > 0
            ? (Icons.schedule, k.muted, 'Checks running')
            : pr.checksTotal > 0
                ? (Icons.check_circle_outline, k.added, 'Checks passed')
                : (Icons.remove, k.faint, 'No checks');
    return Icon(icon, size: 18, color: color, semanticLabel: label);
  }
}
