import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/chat_cache.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/artifact_viewer.dart';
import 'package:pocket_rig/ui/chat/media_view.dart';
import 'package:pocket_rig/ui/rig_screen.dart';
import 'package:pocket_rig/ui/theme.dart';

import 'golden/fixtures.dart';

class _Cache extends ChatCache {
  _Cache(this.media) : super(NativeDatabase.memory());
  final List<RigMedia> media;
  String? asked;
  @override
  Stream<List<RigMedia>> watchRigMedia(String hostId, String rigId) {
    asked = '$hostId/$rigId';
    return Stream.value(media);
  }
}

void main() {
  /// Paths the fake host cannot read; [checks] counts the `readable` calls it got.
  var missing = <String>{};
  var checks = 0;
  var hostDown = false;

  setUp(() {
    animateStatusSpinners = false;
    missing = {};
    checks = 0;
    hostDown = false;
  });
  late _Cache cache;
  tearDown(() async {
    chatCache = null;
    await cache.close();
  });

  Future<void> open(WidgetTester tester, List<RigMedia> media) async {
    cache = _Cache(media);
    chatCache = cache;
    final store = await installFakes();
    SshExec.debugConnect = (h) async {
      if (hostDown) throw Exception('host unreachable');
      return SshExec.fake((c) async {
        if (!c.startsWith('readable ')) return fakeShell(c);
        checks++;
        final paths = c.substring(9).split('\n');
        return [for (final (i, p) in paths.indexed) if (!missing.contains(p)) i].join('\n');
      });
    };
    await tester.pumpWidget(MaterialApp(home: phone(store, RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', tab: 3))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  final now = DateTime.now();
  RigMedia m(String kind, String ref, String? name) => RigMedia(kind, ref, name, now, 'r-conveyor/lead');

  testWidgets('the Code tab lists what the rig made, newest first, from the cache', (tester) async {
    await open(tester, [
      m('file', '/w/docs/retry-design.md', null),
      m('image', '/w/shots/after.png', null),
      m('artifact', 'https://claude.ai/artifact/abc', 'Retry report'),
    ]);
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('retry-design.md'), 200, scrollable: list);

    expect(cache.asked, 'h1/r-conveyor');
    expect(find.text('after.png'), findsOneWidget);
    expect(find.text('Retry report'), findsOneWidget);
    final y = [for (final t in ['retry-design.md', 'after.png', 'Retry report']) tester.getTopLeft(find.text(t)).dy];
    expect(y, [...y]..sort());

    await tester.ensureVisible(find.text('retry-design.md'));
    await tester.pump();
    await tester.tap(find.text('retry-design.md'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ArtifactViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Back').last);
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('after.png'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MediaViewer), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an image or video that was never saved is hidden after one batched check', (tester) async {
    missing = {'/w/shots/phantom.png'};
    await open(tester, [
      m('file', '/w/docs/retry-design.md', null),
      m('image', '/w/shots/phantom.png', null),
      m('image', '/w/shots/after.png', null),
      m('video', '/w/shots/run.mp4', null),
    ]);
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('retry-design.md'), 200, scrollable: list);

    await tester.pump(const Duration(milliseconds: 100));
    expect(checks, 1, reason: 'one readable call for every image and video');
    expect(find.text('phantom.png'), findsNothing);
    expect(find.text('after.png'), findsOneWidget);
    expect(find.text('run.mp4'), findsOneWidget);
    expect(find.text('MADE BY THE RIG · 3'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('when the host cannot be reached everything stays listed', (tester) async {
    hostDown = true;
    missing = {'/w/shots/phantom.png'};
    await open(tester, [m('image', '/w/shots/phantom.png', null), m('file', '/w/docs/retry-design.md', null)]);
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('retry-design.md'), 200, scrollable: list);
    expect(find.text('phantom.png'), findsOneWidget);
    expect(find.text('MADE BY THE RIG · 2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a rig with nothing cached shows no media section', (tester) async {
    await open(tester, []);
    final list = find.byType(Scrollable).first;
    await tester.drag(list, const Offset(0, -3000));
    await tester.pump();
    expect(find.text('Made by the rig'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('more than five: exactly 5 and Show more, which shows the rest in the same list', (tester) async {
    await open(tester, [for (var i = 0; i < 10; i++) m('file', '/w/f$i.md', null)]);
    final list = find.byType(Scrollable).first;
    Future<void> reveal(Finder f) async {
      for (var i = 0; i < 20 && f.evaluate().isEmpty; i++) {
        await tester.drag(list, const Offset(0, -250));
        await tester.pump();
      }
      await tester.ensureVisible(f);
    }

    await reveal(find.text('Show more', skipOffstage: false));
    final files =
        find.byWidgetPredicate((w) => w is Text && RegExp(r'^f\d\.md$').hasMatch(w.data ?? ''), skipOffstage: false);
    expect(files, findsNWidgets(5));
    expect(find.text('f9.md', skipOffstage: false), findsNothing);

    // Its tile is built but below the fold in this harness: press it without a pointer.
    tester.widget<ListTile>(find.widgetWithText(ListTile, 'Show more', skipOffstage: false)).onTap!();
    await tester.pump();
    expect(files, findsNWidgets(10));
    expect(find.text('f9.md', skipOffstage: false), findsOneWidget);
    expect(find.text('Show more', skipOffstage: false), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
