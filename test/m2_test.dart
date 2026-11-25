import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/chat/session_log.dart';
import 'package:pocket_rig/chat/transcript.dart';
import 'package:pocket_rig/data/git_status.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/artifact_viewer.dart';
import 'package:pocket_rig/ui/chat/code_view.dart';
import 'package:pocket_rig/ui/chat/message_views.dart';
import 'package:pocket_rig/ui/chat_screen.dart';

/// Lines in Claude Code's session-log shape.
List<String> sampleLog() => [
      {'type': 'summary', 'summary': 'Graph tab', 'leafUuid': 'x'},
      {
        'type': 'user', 'uuid': 'u1', 'timestamp': '2026-11-01T09:00:00Z', 'cwd': '/w/app', 'gitBranch': 'main',
        'message': {'role': 'user', 'content': 'Add a graph tab'},
      },
      {
        'type': 'user', 'uuid': 'meta', 'isMeta': true,
        'message': {'role': 'user', 'content': 'Caveat: local commands'},
      },
      {
        'type': 'assistant', 'uuid': 'a1',
        'message': {'id': 'msg_1', 'role': 'assistant', 'content': [{'type': 'text', 'text': 'Looking at the layout.'}]},
      },
      {
        'type': 'assistant', 'uuid': 'a2',
        'message': {
          'id': 'msg_1', 'role': 'assistant',
          'content': [{'type': 'tool_use', 'id': 't1', 'name': 'Read', 'input': {'file_path': '/w/app/lib/a.dart'}}],
        },
      },
      {
        'type': 'user', 'uuid': 'r1',
        'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 't1', 'content': 'one\ntwo\nthree'}]},
      },
      {
        'type': 'assistant', 'uuid': 'a3',
        'message': {
          'id': 'msg_2', 'role': 'assistant',
          'content': [
            {'type': 'tool_use', 'id': 't2', 'name': 'Edit', 'input': {'file_path': '/w/app/lib/a.dart', 'old_string': 'a', 'new_string': 'b'}},
            {'type': 'tool_use', 'id': 't3', 'name': 'Bash', 'input': {'command': 'flutter test', 'description': 'Run tests'}},
          ],
        },
      },
      {
        'type': 'user', 'uuid': 'r2',
        'message': {'role': 'user', 'content': [
          {'type': 'tool_result', 'tool_use_id': 't2', 'content': [{'type': 'text', 'text': 'ok'}]},
          {'type': 'tool_result', 'tool_use_id': 't3', 'content': 'Some tests failed', 'is_error': true},
        ]},
      },
      {
        'type': 'assistant', 'uuid': 'a4',
        'message': {'id': 'msg_3', 'role': 'assistant', 'content': [
          {'type': 'thinking', 'thinking': 'hmm'},
          {'type': 'text', 'text': 'Here is the flow:\n\n```mermaid\ngraph TD; A-->B\n```\n\nDone.'},
        ]},
      },
      {
        'type': 'user', 'uuid': 'c1',
        'message': {'role': 'user', 'content': '<command-name>/compact</command-name>\n<command-args></command-args>'},
      },
      {'type': 'assistant', 'uuid': 'side', 'isSidechain': true, 'message': {'id': 'm9', 'content': [{'type': 'text', 'text': 'sub'}]}},
    ].map(jsonEncode).toList()
      ..add('{not json')
      ..add('');

void main() {
  group('transcript', () {
    test('turns a session log into bubbles, folded tools and notes', () {
      final t = ChatTranscript()..addAll(sampleLog());
      final kinds = t.items.map((i) => i.runtimeType.toString()).toList();
      expect(kinds, ['UserMessage', 'AssistantMessage', 'ToolCall', 'ToolCall', 'ToolCall', 'AssistantMessage', 'NoteItem']);
      final read = t.items[2] as ToolCall;
      expect((read.verb, read.target, read.shortResult), ('READ', '/w/app/lib/a.dart', '3 lines'));
      final edit = t.items[3] as ToolCall;
      expect(edit.writtenPath, '/w/app/lib/a.dart');
      expect(edit.result, 'ok');
      final bash = t.items[4] as ToolCall;
      expect((bash.verb, bash.target, bash.isError), ('BASH', 'Run tests', true));
      expect(bash.shortResult, 'error: Some tests failed');
      expect((t.items[6] as NoteItem).text, '/compact');
      expect(t.artifacts, ['/w/app/lib/a.dart']);
      expect(t.cwd, '/w/app');
      expect(t.gitBranch, 'main');
    });

    test('re-adding a line is a no-op', () {
      final t = ChatTranscript()..addAll(sampleLog());
      final n = t.items.length;
      expect(t.add(sampleLog()[1]), isFalse);
      expect(t.items.length, n);
    });

    test('text blocks in one message join until a tool call splits them', () {
      final t = ChatTranscript()
        ..add(jsonEncode({'type': 'assistant', 'uuid': 'x1', 'message': {'id': 'm', 'content': [{'type': 'text', 'text': 'A'}]}}))
        ..add(jsonEncode({'type': 'assistant', 'uuid': 'x2', 'message': {'id': 'm', 'content': [{'type': 'text', 'text': 'B'}]}}));
      expect((t.items.single as AssistantMessage).text, 'A\n\nB');
    });
  });

  test('fences split prose, code and mermaid; an open fence runs to the end', () {
    final s = splitFences('Intro\n\n```dart\nvoid main() {}\n```\nMid\n```mermaid\ngraph TD; A-->B\n```\n```py\nprint(1)');
    expect(s.map((x) => x.isCode ? 'code:${x.language}' : 'prose').toList(),
        ['prose', 'code:dart', 'prose', 'code:mermaid', 'code:py']);
    expect(s[1].body, 'void main() {}');
    expect(s[3].isMermaid, isTrue);
    expect(s[4].body, 'print(1)');
  });

  test('project slugs and the locate script', () {
    expect(claudeProjectSlugs('/Users/me/my.app'), ['-Users-me-my-app', '-Users-me-my.app']);
    final seat = Seat(rigId: 'r', logicalId: 'impl', cwd: '/Users/me/app', resumeToken: 'abc-123');
    final script = locateLogScript(seat);
    expect(script, contains(r'"$base"/*/abc-123.jsonl'));
    expect(script, contains("'-Users-me-app'"));
    expect(script.indexOf('abc-123'), lessThan(script.indexOf('-Users-me-app')));
    // A token with shell characters is ignored rather than quoted.
    expect(locateLogScript(Seat(rigId: 'r', logicalId: 'x', resumeToken: r'$(rm -rf)')), isNot(contains('rm -rf')));
  });

  test('tail splits lines across chunks, keeps the offset, drops a cut first line', () {
    final tail = SessionLogTail(Host(id: 'h', name: 'h', address: 'h', sshUser: 'u'), '/x.jsonl');
    final got = <String>[];
    tail.lines.listen(got.add);
    final bytes = utf8.encode('tail of a cut line\n{"a":1}\n{"b":');
    tail.feed(Uint8List.fromList(bytes), dropFirstLine: true);
    tail.feed(Uint8List.fromList(utf8.encode('2}\n')));
    return Future<void>.delayed(Duration.zero, () {
      expect(got, ['{"a":1}', '{"b":2}']);
      expect(tail.offset, bytes.length + 3);
    });
  });

  test('languages from fence tags and paths; artifact kinds', () {
    expect(languageFor('ts'), 'typescript');
    expect(languageFor('/w/app/lib/a.dart'), 'dart');
    expect(languageFor('README'), isNull);
    expect(artifactKind('/a/notes.md'), ArtifactKind.markdown);
    expect(artifactKind('/a/index.html'), ArtifactKind.html);
    expect(artifactKind('/a/main.go'), ArtifactKind.code);
  });

  testWidgets('chat pieces render: bubbles, code, tools, artifact, changes and PR', (tester) async {
    final t = ChatTranscript()..addAll(sampleLog());
    final git = GitStatus(
      branch: 'main',
      root: '/w/app',
      changedFiles: 1,
      changes: [FileChange('lib/a.dart', 4, 1)],
      pr: PullRequest(number: 7, title: 'Graph tab', state: 'OPEN', url: 'https://example.com/pr/7', checksPassed: 2, checksFailed: 1),
    );
    String? opened;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          for (final i in t.items)
            switch (i) {
              UserMessage(:final text) => UserBubble(text),
              AssistantMessage(:final text) => AssistantBody(text, renderMermaid: false),
              NoteItem(:final text) => NoteLine(text),
              ToolCall(:final writtenPath) when writtenPath != null => ArtifactTile(path: writtenPath, onOpen: () => opened = writtenPath),
              final ToolCall c => ToolRow(c),
            },
          ChangesCard(git: git, onOpen: (p) => opened = p),
          PrCard(pr: git.pr!),
        ]),
      ),
    ));
    expect(find.text('Add a graph tab'), findsOneWidget);
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.text('Open pull request'), findsOneWidget);
    expect(find.textContaining('Checks 2 of 3 passed · 1 failing'), findsOneWidget);
    expect(find.text('1 file changed'), findsOneWidget);
    await tester.tap(find.text('a.dart'));
    expect(opened, '/w/app/lib/a.dart');
    await tester.tap(find.text('lib/a.dart'));
    expect(opened, '/w/app/lib/a.dart');
    // Tap a folded tool row to expand it.
    await tester.tap(find.textContaining('Run tests'));
    await tester.pump();
    expect(find.textContaining('\$ flutter test'), findsOneWidget);
    // A tap on the output folds it again.
    await tester.tap(find.textContaining('\$ flutter test'));
    await tester.pump();
    expect(find.textContaining('\$ flutter test'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the git bar opens folder status with the changes and PR', (tester) async {
    final git = GitStatus(
      branch: 'main',
      root: '/w/app',
      changedFiles: 1,
      changes: [FileChange('lib/a.dart', 4, 1)],
      pr: PullRequest(number: 7, title: 'Graph tab', state: 'OPEN'),
    );
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => Scaffold(body: GitBar(git: git, onTap: () => showGitSheet(context, git)))),
    ));
    expect(find.text('1 file changed'), findsNothing);
    await tester.tap(find.text('main'));
    await tester.pumpAndSettle();
    expect(find.text('Folder status'), findsOneWidget);
    expect(find.textContaining('whichever session made them'), findsOneWidget);
    expect(find.text('1 file changed'), findsOneWidget);
    expect(find.text('#7 Graph tab'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool group shows what is running and folds what is done', (tester) async {
    ToolCall run(String file) => ToolCall(file, null, id: file, name: 'Read', input: {'file_path': file});
    ToolCall read(String file) => run(file)..result = 'body of $file';
    Widget app(List<ToolCall> calls) => MaterialApp(home: Scaffold(body: ToolGroup(calls, key: const ValueKey('g'))));

    // Only running calls: nothing to reveal, so no button.
    await tester.pumpWidget(app([run('a.dart'), run('b.dart')]));
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.text('b.dart'), findsOneWidget);
    expect(find.textContaining('finished'), findsNothing);

    // Running calls stay visible; the finished ones sit behind the button.
    await tester.pumpWidget(app([read('a.dart'), read('b.dart'), run('c.dart'), run('d.dart')]));
    expect(find.text('c.dart'), findsOneWidget);
    expect(find.text('d.dart'), findsOneWidget);
    expect(find.text('a.dart'), findsNothing);
    await tester.tap(find.text('Show 2 finished'));
    await tester.pump();
    expect(find.text('a.dart'), findsOneWidget);
    await tester.tap(find.text('Hide 2 finished'));
    await tester.pump();
    expect(find.text('a.dart'), findsNothing);

    // All done: everything folds into the count.
    await tester.pumpWidget(app([read('a.dart'), read('b.dart'), read('c.dart'), read('d.dart')]));
    expect(find.text('4 tool calls'), findsOneWidget);
    expect(find.text('d.dart'), findsNothing);

    await tester.tap(find.text('4 tool calls'));
    await tester.pump();
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.textContaining('body of a.dart'), findsNothing);

    await tester.tap(find.text('a.dart'));
    await tester.pump();
    expect(find.textContaining('body of a.dart'), findsOneWidget);

    await tester.tap(find.text('4 tool calls'));
    await tester.pump();
    expect(find.text('a.dart'), findsNothing);

    // A failure stays visible in the folded count.
    await tester.pumpWidget(app([read('a.dart'), read('b.dart')..isError = true]));
    expect(find.text('2 tool calls · 1 failed'), findsOneWidget);

    // A lone call has nothing to fold: tapping it opens its details directly.
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ToolGroup([read('e.dart')]))));
    expect(find.textContaining('tool calls'), findsNothing);
    await tester.tap(find.text('e.dart'));
    await tester.pump();
    expect(find.textContaining('body of e.dart'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
