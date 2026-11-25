import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/git_status.dart';

void main() {
  test('a PR from gh carries its size, and the summary line shows it', () {
    // The shape `gh pr view --json number,title,…,changedFiles,additions,deletions` prints.
    final pr = PullRequest.parse('{"number":87,"title":"Worktree details","state":"MERGED",'
        '"url":"https://github.com/knezzz/PocketRig/pull/87","statusCheckRollup":[],'
        '"changedFiles":31,"additions":1384,"deletions":269}')!;
    expect(pr.size, '31 files +1384 −269');
    expect(prLine(pr), 'Merged · no review · 31 files +1384 −269');
    expect(PullRequest.fields, contains('changedFiles,additions,deletions'));
  });

  test('an older gh without the size still parses; the summary just leaves it out', () {
    final pr = PullRequest.parse('{"number":3,"title":"x","state":"OPEN"}')!;
    expect(pr.size, isNull);
    expect(prLine(pr), 'Open · no review');
    expect(PullRequest.parse('{"number":1,"title":"one","state":"OPEN","changedFiles":1,"additions":2}')!.size,
        '1 file +2 −0');
  });

  test('one wording for the review state, in the one line every screen shows', () {
    final pr = PullRequest.parse('{"number":3,"title":"x","state":"OPEN","reviewDecision":"REVIEW_REQUIRED",'
        '"statusCheckRollup":[{"conclusion":"SUCCESS"},{"status":"IN_PROGRESS"}]}')!;
    expect(pr.reviewLabel, 'review requested');
    expect(prLine(pr), 'Open · checks 1/2 · review requested');
  });
}
