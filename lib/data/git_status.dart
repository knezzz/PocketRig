import 'dart:convert';

/// One file from `git diff --numstat`. Binary files have null counts.
class FileChange {
  FileChange(this.path, this.added, this.deleted);
  final String path;
  final int? added;
  final int? deleted;
}

/// One checkout from `git worktree list --porcelain`; the main one comes first.
class Worktree {
  Worktree(this.path, this.branch, {this.upstream, this.ahead = 0, this.behind = 0, this.changed = 0});
  final String path;

  /// The short branch name, or null when HEAD is detached.
  final String? branch;

  /// The branch it pushes to, or null when it was never pushed.
  final String? upstream;
  final int ahead;
  final int behind;

  /// Files changed or untracked, not yet committed.
  final int changed;

  /// What's not on the remote yet: "pushed", "2 to push · 3 changed", "not pushed".
  String get pushState => [
        if (upstream == null && branch != null) 'not pushed' else if (ahead > 0) '$ahead to push',
        if (behind > 0) '$behind behind',
        if (changed > 0) '$changed changed',
        if (upstream != null && ahead == 0 && behind == 0 && changed == 0) 'pushed',
      ].join(' · ');

  /// `git worktree list --porcelain`, each block followed by `git status
  /// --porcelain=v2 --branch` headers and a `changed N` line.
  static String script(String dir) => 'cd $dir 2>/dev/null && git worktree list --porcelain 2>/dev/null | $_statusEach';

  static const _statusEach = r'''while IFS= read -r l; do
  echo "$l"
  case "$l" in "worktree "*)
    s=$(git -C "${l#worktree }" status --porcelain=v2 --branch 2>/dev/null)
    printf '%s\n' "$s" | grep -E '^# branch\.(upstream|ab) '
    echo "changed $(printf '%s\n' "$s" | grep -cv -e '^#' -e '^$')" ;;
  esac
done''';

  String get name => path.split('/').where((p) => p.isNotEmpty).lastOrNull ?? path;

  static List<Worktree> parse(String porcelain) => [
        for (final block in porcelain.split(RegExp(r'\n\s*\n')))
          if (RegExp(r'^worktree (.+)$', multiLine: true).firstMatch(block) case final m?)
            Worktree(
              m.group(1)!.trim(),
              RegExp(r'^branch refs/heads/(.+)$', multiLine: true).firstMatch(block)?.group(1)?.trim(),
              upstream: RegExp(r'^# branch\.upstream (.+)$', multiLine: true).firstMatch(block)?.group(1)?.trim(),
              ahead: int.tryParse(RegExp(r'^# branch\.ab \+(\d+)', multiLine: true).firstMatch(block)?.group(1) ?? '') ?? 0,
              behind: int.tryParse(RegExp(r'^# branch\.ab \S+ -(\d+)', multiLine: true).firstMatch(block)?.group(1) ?? '') ?? 0,
              changed: int.tryParse(RegExp(r'^changed (\d+)', multiLine: true).firstMatch(block)?.group(1) ?? '') ?? 0,
            ),
      ];
}

/// The pull request for the current branch, from `gh pr view --json …`.
class PullRequest {
  PullRequest({
    required this.number,
    required this.title,
    required this.state,
    this.url,
    this.reviewDecision,
    this.checksPassed = 0,
    this.checksFailed = 0,
    this.checksPending = 0,
    this.headRef,
    this.baseRef,
    this.changedFiles,
    this.additions,
    this.deletions,
    this.isDraft = false,
  });

  /// A draft PR (`gh pr view --json isDraft`).
  final bool isDraft;

  /// The PR's size: files touched, lines added and removed (null: gh didn't say).
  final int? changedFiles;
  final int? additions;
  final int? deletions;

  /// "31 files +1384 −269", or null when the size isn't known.
  String? get size => changedFiles == null
      ? null
      : '$changedFiles ${changedFiles == 1 ? 'file' : 'files'} +${additions ?? 0} −${deletions ?? 0}';

  final String? headRef;
  final String? baseRef;
  final int number;
  final String title;

  /// OPEN | CLOSED | MERGED
  final String state;
  final String? url;

  /// APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | null
  final String? reviewDecision;
  final int checksPassed;
  final int checksFailed;
  final int checksPending;

  /// What [parse] reads, for `gh pr … --json`.
  static const fields =
      'number,title,state,url,statusCheckRollup,reviewDecision,headRefName,baseRefName,changedFiles,additions,deletions,isDraft';

  int get checksTotal => checksPassed + checksFailed + checksPending;

  /// passing | failing | pending | none
  String get checks => checksTotal == 0
      ? 'none'
      : checksFailed > 0
          ? 'failing'
          : checksPending > 0
              ? 'pending'
              : 'passing';

  String get reviewLabel => switch (reviewDecision) {
        'APPROVED' => 'approved',
        'CHANGES_REQUESTED' => 'changes requested',
        'REVIEW_REQUIRED' => 'review requested',
        _ => 'no review',
      };

  static PullRequest? parse(String text) => fromJson(_decode(text));

  /// The array `gh pr list --json …` prints.
  static List<PullRequest> parseList(String text) => switch (_decode(text)) {
        List l => l.map(fromJson).nonNulls.toList(),
        _ => const [],
      };

  static Object? _decode(String text) {
    try {
      return jsonDecode(text.trim());
    } catch (_) {
      return null;
    }
  }

  static PullRequest? fromJson(Object? j) {
    if (j is! Map || j['number'] is! num) return null;
    var pass = 0, fail = 0, pend = 0;
    final rollup = j['statusCheckRollup'];
    if (rollup is List) {
      for (final c in rollup.whereType<Map>()) {
        // CheckRun: status + conclusion. StatusContext: state.
        final conclusion = '${c['conclusion'] ?? ''}'.toUpperCase();
        final status = '${c['status'] ?? ''}'.toUpperCase();
        final state = '${c['state'] ?? ''}'.toUpperCase();
        if (state.isNotEmpty) {
          if (state == 'SUCCESS') {
            pass++;
          } else if (state == 'PENDING' || state == 'EXPECTED') {
            pend++;
          } else {
            fail++;
          }
        } else if (status.isNotEmpty && status != 'COMPLETED') {
          pend++;
        } else if (const {'SUCCESS', 'NEUTRAL', 'SKIPPED'}.contains(conclusion)) {
          pass++;
        } else {
          fail++;
        }
      }
    }
    final review = j['reviewDecision'];
    return PullRequest(
      number: (j['number'] as num).toInt(),
      title: '${j['title'] ?? ''}',
      state: '${j['state'] ?? 'OPEN'}',
      url: j['url'] as String?,
      reviewDecision: review is String && review.isNotEmpty ? review : null,
      checksPassed: pass,
      checksFailed: fail,
      checksPending: pend,
      headRef: j['headRefName'] as String?,
      baseRef: j['baseRefName'] as String?,
      changedFiles: (j['changedFiles'] as num?)?.toInt(),
      additions: (j['additions'] as num?)?.toInt(),
      deletions: (j['deletions'] as num?)?.toInt(),
      isDraft: j['isDraft'] == true,
    );
  }
}

/// Branch, ahead/behind, changed files and PR for one folder, from one SSH
/// call. [isRepo] is false when the folder is not a git checkout.
class GitStatus {
  GitStatus({
    this.isRepo = true,
    this.branch,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    this.changedFiles = 0,
    this.changes = const [],
    this.pr,
    this.root,
    this.fileStatus = const {},
    this.untracked = const [],
  });

  /// M / A / D / R per path, from `git status` (index side first).
  final Map<String, String> fileStatus;

  /// New files git doesn't track yet (no line counts).
  final List<String> untracked;

  /// Everything the changes card lists: tracked changes, then new files.
  List<(String status, String path, String delta)> get changeRows => [
        for (final c in changes)
          (
            fileStatus[c.path] ?? 'M',
            c.path,
            c.added == null ? 'binary' : (c.deleted == 0 ? '+${c.added}' : '+${c.added} −${c.deleted}')
          ),
        for (final u in untracked)
          if (!changes.any((c) => c.path == u)) ('A', u, 'new'),
      ];

  final bool isRepo;

  /// The checkout's top folder; numstat paths are relative to it.
  final String? root;
  final String? branch;
  final String? upstream;
  final int ahead;
  final int behind;

  /// Entries in `git status` (staged, unstaged and untracked).
  final int changedFiles;

  /// Tracked changes against HEAD, with line counts.
  final List<FileChange> changes;
  final PullRequest? pr;

  int get added => changes.fold(0, (n, c) => n + (c.added ?? 0));
  int get deleted => changes.fold(0, (n, c) => n + (c.deleted ?? 0));

  /// Markers between the sections of the combined command's output.
  static const _status = '@@pocketrig-status';
  static const _numstat = '@@pocketrig-numstat';
  static const _pr = '@@pocketrig-pr';

  /// The shell script run in the folder (inside a login shell, so Homebrew's
  /// `gh` is on PATH).
  static String script(String dirExpr) => 'cd $dirExpr 2>/dev/null || exit 0; '
      'git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0; '
      'echo $_status; printf "# pocketrig.root %s\\n" "\$(git rev-parse --show-toplevel)"; '
      'git status --porcelain=v2 -b 2>/dev/null; '
      'echo $_numstat; git diff HEAD --numstat 2>/dev/null; '
      'echo $_pr; command -v gh >/dev/null 2>&1 && '
      'gh pr view --json ${PullRequest.fields} 2>/dev/null; true';

  factory GitStatus.parse(String out) {
    if (!out.contains(_status)) return GitStatus(isRepo: false);
    String section(String start, String? end) {
      final a = out.indexOf(start);
      if (a < 0) return '';
      final from = a + start.length;
      final b = end == null ? -1 : out.indexOf(end, from);
      return out.substring(from, b < 0 ? out.length : b);
    }

    String? branch, upstream, root;
    var ahead = 0, behind = 0, files = 0;
    final status = <String, String>{};
    final untracked = <String>[];
    String letter(String xy) {
      final x = xy.isNotEmpty ? xy[0] : '.';
      final y = xy.length > 1 ? xy[1] : '.';
      final c = x != '.' ? x : y;
      return c == '.' ? 'M' : c;
    }

    for (final line in const LineSplitter().convert(section(_status, _numstat))) {
      if (line.startsWith('# pocketrig.root ')) {
        root = line.substring(17).trim();
      } else if (line.startsWith('# branch.head ')) {
        final b = line.substring(14).trim();
        branch = b == '(detached)' ? 'detached' : b;
      } else if (line.startsWith('# branch.upstream ')) {
        upstream = line.substring(18).trim();
      } else if (line.startsWith('# branch.ab ')) {
        final parts = line.substring(12).trim().split(' ');
        if (parts.length == 2) {
          ahead = int.tryParse(parts[0].replaceFirst('+', '')) ?? 0;
          behind = (int.tryParse(parts[1]) ?? 0).abs();
        }
      } else if (line.length > 1 && '12u?'.contains(line[0]) && line[1] == ' ') {
        files++;
        // 1 XY sub mH mI mW hH hI path | 2 … Xscore path<TAB>orig | ? path
        final parts = line.split(' ');
        if (line[0] == '?') {
          untracked.add(line.substring(2));
        } else if (line[0] == '1' && parts.length >= 9) {
          status[parts.sublist(8).join(' ')] = letter(parts[1]);
        } else if (line[0] == '2' && parts.length >= 10) {
          status[parts.sublist(9).join(' ').split('\t').first] = letter(parts[1]);
        } else if (line[0] == 'u' && parts.length >= 11) {
          status[parts.sublist(10).join(' ')] = 'U';
        }
      }
    }

    final changes = <FileChange>[];
    for (final line in const LineSplitter().convert(section(_numstat, _pr))) {
      final parts = line.split('\t');
      if (parts.length < 3) continue;
      changes.add(FileChange(parts.sublist(2).join('\t'), int.tryParse(parts[0]), int.tryParse(parts[1])));
    }

    return GitStatus(
      branch: branch,
      upstream: upstream,
      ahead: ahead,
      behind: behind,
      changedFiles: files,
      changes: changes,
      pr: PullRequest.parse(section(_pr, null)),
      root: root == null || root.isEmpty ? null : root,
      fileStatus: status,
      untracked: untracked,
    );
  }
}

/// "Open · checks 2/3 · review requested · +142 −38": a pull request's one line.
String prLine(PullRequest pr) => [
      if (pr.state.isNotEmpty) '${pr.state[0]}${pr.state.substring(1).toLowerCase()}',
      if (pr.checksTotal > 0) 'checks ${pr.checksPassed}/${pr.checksTotal}',
      pr.reviewLabel,
      if (pr.size case final size?) size,
    ].join(' · ');
