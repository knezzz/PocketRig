import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/project_actions.dart' show projectNameOf;

void main() {
  test('a folder is shown by its main checkout\'s name, everywhere: a worktree reads as its project', () {
    expect(folderName('/w/app'), 'app');
    expect(folderName('/w/app/'), 'app');
    expect(folderName('/w/app/.claude/worktrees/feat'), 'app', reason: 'not "feat"');
    expect(folderName('/w/app/.claude/worktrees/feat/lib'), 'app');
    expect(folderName('/w/app/lib'), 'lib', reason: 'a subfolder that is not a worktree is its own name');
    expect(folderName('/'), '/');
    expect(projectNameOf('/w/app/.claude/worktrees/feat'), 'app');
    expect(Project(path: '/w/app/.claude/worktrees/feat').name, 'app');
    // A loose agent in a worktree reads as its project too (it said the worktree's name on Recent: 'no rig › feat').
    expect(LooseAgent(id: 'a', cwd: '/w/app/.claude/worktrees/feat').project, 'app');
    expect(LooseAgent(id: 'a').project, isNull);
  });
}
