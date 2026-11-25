import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/chat/session_log.dart';
import 'package:pocket_rig/chat/transcript.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat/media_view.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

/// A 1×1 PNG.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

List<String> _replay = const [];

class _ReplayTail extends SessionLogTail {
  _ReplayTail(super.host, super.path);
  @override
  Future<void> start() async {
    reportStatus('live');
    feed(Uint8List.fromList(utf8.encode('${_replay.join('\n')}\n')));
  }
}

void main() {
  setUp(() => animateStatusSpinners = false);

  test('media paths: absolute, home and relative files; never URLs', () {
    expect(
        mediaPathsIn(
            'Saved /tmp/shot.png, ~/Movies/demo.MOV and ./out/frame.jpg. See https://x.dev/a.png or notes.md.', '/w'),
        ['/tmp/shot.png', '~/Movies/demo.MOV', '/w/out/frame.jpg']);
    expect(mediaPathsIn('![chart](docs/chart.webp)', null), isEmpty, reason: 'relative needs a folder');
    expect(mediaPathsIn('/a/b.png /a/b.png', null), ['/a/b.png']);
    expect([isVideoPath('/a/b.mp4'), isImagePath('/a/b.mp4'), isImagePath('/a/.png')], [true, false, false]);
  });

  testWidgets('an image the agent saved shows inline and in a pill, and opens full screen', (tester) async {
    final store = await installFakes();
    final asked = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((c) async {
          // Only the screenshot exists; the other path is just named in the text.
          if (c.startsWith('readable ')) {
            final paths = c.substring(9).split('\n');
            return [paths.indexOf('/tmp/shot.png'), paths.indexOf('/tmp/old.png')].join('\n');
          }
          if (!c.startsWith('download ')) return fakeShell(c);
          asked.add(c);
          return _png;
        });
    SessionLogTail.factory = _ReplayTail.new;
    _replay = [
      jsonEncode({
        'type': 'assistant',
        'uuid': 'a1',
        'message': {
          'id': 'm1',
          'content': [
            {
              'type': 'tool_use',
              'id': 't1',
              'name': 'Bash',
              'input': {'command': 'screencapture -x /tmp/shot.png', 'description': 'Not /tmp/missing.png, after /tmp/old.png'}
            }
          ]
        }
      }),
      jsonEncode({
        'type': 'user',
        'uuid': 'r1',
        'message': {
          'content': [
            {'type': 'tool_result', 'tool_use_id': 't1', 'content': ''}
          ]
        }
      }),
    ];
    final seat = Seat(rigId: '', logicalId: 'scratch', sessionName: 'scratch', runtime: 'claude-code', cwd: '/w');
    await tester.pumpWidget(MaterialApp(home: phone(store, ChatScreen(rigName: 'no rig', seat: seat, asChat: true))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(MediaTile), findsNWidgets(2), reason: 'a path the host can\'t read is left out');
    expect(asked.toSet(), {'download /tmp/shot.png', 'download /tmp/old.png'});
    expect(asked.length, 2, reason: 'each thumbnail is fetched once');

    await tester.tap(find.byType(MediaTile).first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(MediaViewer), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(asked.length, 2, reason: 'the viewer reuses the fetched bytes');
    expect(find.textContaining('shot.png · 1 of 2'), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('old.png · 2 of 2'), findsOneWidget, reason: 'swiping moves to the next image');
    // The strip under the image: a thumbnail shows its image.
    await tester.tap(find.descendant(of: find.byType(ListView), matching: find.byType(MediaTile)).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('shot.png · 1 of 2'), findsOneWidget, reason: 'a thumbnail in the strip switches back');
    expect(find.byTooltip('Draw and send to scratch'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
