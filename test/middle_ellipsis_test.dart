import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/common.dart';

void main() {
  test('a long path is cut in the middle, so its last folder stays', () {
    expect(middleEllipsis('~/code/app'), '~/code/app');
    final cut = middleEllipsis('~/code/app/.claude/worktrees/flaky-ci', max: 30);
    expect(cut.length, 30);
    expect(cut, startsWith('~/code/app/'));
    expect(cut, endsWith('flaky-ci'));
    expect(cut, contains('…'));
  });
}
