import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/chat_cache.dart';
import 'package:pocket_rig/models.dart' show Seat;
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/agent_panels.dart';
import 'package:pocket_rig/ui/agent_view_switch.dart';
import 'package:pocket_rig/ui/artifact_viewer.dart' show ArtifactViewer, withDarkScheme;
import 'package:pocket_rig/main.dart' show AppScope;
import 'package:pocket_rig/ui/chat/media_view.dart' show MediaViewer;
import 'package:pocket_rig/ui/theme.dart' show Tokens, buildTheme;

import 'golden/fixtures.dart';

String _line(String type, List<Map<String, Object?>> content, String at) => jsonEncode({
      'type': type,
      'uuid': '$type$at',
      'timestamp': at,
      'cwd': '/w',
      'message': {'id': 'm$at', 'content': content},
    });

/// The cache's media for one chat, as a plain stream: drift's live query leaves timers a widget test can't drain.
class _Cache extends ChatCache {
  _Cache(this.media) : super(NativeDatabase.memory());
  final List<RigMedia> media;
  String? asked;
  @override
  Stream<List<RigMedia>> watchChatMedia(String hostId, String key) {
    asked = '$hostId/$key';
    return Stream.value(media);
  }
}

void main() {
  test('a dark HTML preview defaults to a dark page: the colour scheme goes first in the head, wherever the page starts', () {
    const meta = '<meta name="color-scheme" content="dark">';
    expect(withDarkScheme('<!doctype html><html><head><title>x</title></head><body>a</body></html>'),
        '<!doctype html><html><head>$meta<title>x</title></head><body>a</body></html>');
    expect(withDarkScheme('<HTML lang="en"><body>a</body></HTML>'), '<HTML lang="en"><head>$meta</head><body>a</body></HTML>');
    expect(withDarkScheme('<!DOCTYPE html>\n<p>a</p>'), '<!DOCTYPE html>$meta\n<p>a</p>', reason: 'after the doctype, which must stay first');
    expect(withDarkScheme('<p>a</p>'), '$meta<p>a</p>');
  });

  test('an agent\'s panels list the images its tools touched and the files it wrote, not prose mentions', () async {
    final c = ChatCache(NativeDatabase.memory());
    addTearDown(c.close);
    await c.restart('h', 'r1/lead', '/a');
    await c.append('h', 'r1/lead', '/a', 0, 10, false, [
      _line(
          'assistant',
          [
            {
              'type': 'tool_use',
              'id': 't1',
              'name': 'Read',
              'input': {'file_path': '/w/shot.png'}
            }
          ],
          '2026-11-12T10:00:00Z'),
      _line(
          'assistant',
          [
            {
              'type': 'tool_use',
              'id': 't2',
              'name': 'Edit',
              'input': {'file_path': '/w/lib/a.dart', 'old_string': 'a', 'new_string': 'b'}
            }
          ],
          '2026-11-12T10:01:00Z'),
      _line(
          'assistant',
          [
            {'type': 'text', 'text': 'Maybe compare it with old.png later.'}
          ],
          '2026-11-12T10:02:00Z'),
    ]);
    await c.restart('h', 'r1/lead2', '/b');
    await c.append('h', 'r1/lead2', '/b', 0, 10, false, [
      _line(
          'assistant',
          [
            {
              'type': 'tool_use',
              'id': 't3',
              'name': 'Read',
              'input': {'file_path': '/w/other.png'}
            }
          ],
          '2026-11-12T10:03:00Z'),
    ]);
    final got = await c.watchChatMedia('h', 'r1/lead').first;
    expect([for (final m in got) (m.kind, m.ref)], [('file', '/w/lib/a.dart'), ('image', '/w/shot.png')]);
  });

  test('an image named in prose and then read is counted; one only listed in a tool\'s output is not', () async {
    final c = ChatCache(NativeDatabase.memory());
    addTearDown(c.close);
    await c.restart('h', 'r1/lead', '/a');
    await c.append('h', 'r1/lead', '/a', 0, 10, false, [
      _line(
          'assistant',
          [
            {'type': 'text', 'text': 'Let me look at /w/shot.png.'},
            {
              'type': 'tool_use',
              'id': 't1',
              'name': 'Read',
              'input': {'file_path': '/w/shot.png'}
            },
            {
              'type': 'tool_use',
              'id': 't2',
              'name': 'Bash',
              'input': {'command': 'ls test/golden'}
            },
          ],
          '2026-11-12T10:00:00Z'),
      _line(
          'user',
          [
            {'type': 'tool_result', 'tool_use_id': 't2', 'content': '/w/golden/a.png\n/w/golden/b.png'}
          ],
          '2026-11-12T10:00:01Z'),
    ]);
    final got = await c.watchChatMedia('h', 'r1/lead').first;
    expect([for (final m in got) m.ref], ['/w/shot.png']);
  });

  group('the dock and the tile counts', () {
    late _Cache cache;
    setUp(() async {
      agentPanels.value = const PanelLayout();
      agentPanelsFile = () async => null;
    });
    tearDown(() async {
      SshExec.debugConnect = null;
      chatCache = null;
      await cache.close();
    });

    Future<void> pump(WidgetTester tester, Widget child) async {
      final store = await installFakes();
      final now = DateTime.now();
      final key = chatKey(seatFromFixture('r-conveyor', 'lead'));
      chatCache = cache = _Cache([
        RigMedia('file', '/w/c.dart', null, now, key),
        RigMedia('image', '/w/b.png', null, now, key),
        RigMedia('image', '/w/a.png', null, now, key),
        RigMedia('file', '/w/notes.md', null, now, key),
        RigMedia('file', '/w/report.html', null, now, key),
        // Written after any dock was opened: "new" the second time the dock shows.
        RigMedia('file', '/w/fresh.md', null, now.add(const Duration(hours: 1)), key),
      ]);
      // Thumbnails stay placeholders: no host to download from.
      SshExec.debugConnect = (_) async => throw StateError('no route to host');
      await tester.pumpWidget(MaterialApp(home: phone(store, Scaffold(body: child))));
      await tester.pump();
      expect(cache.asked, '${store.active!.id}/$key');
    }

    testWidgets('a tile shows how many images and files', (tester) async {
      await pump(tester, Center(child: AgentMediaCounts(seat: seatFromFixture('r-conveyor', 'lead'))));
      expect(find.bySemanticsLabel('2 images'), findsOneWidget);
      expect(find.bySemanticsLabel('1 file changed'), findsOneWidget, reason: 'a .md or .html is not a code edit');
      expect(find.bySemanticsLabel('3 artifacts'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Artifacts shows cards with their kind, marks what is new on a second look, and a tap opens the viewer',
        (tester) async {
      await pump(tester, Row(children: [const Spacer(), AgentPanelDock(seat: seatFromFixture('r-conveyor', 'lead'))]));
      await tester.tap(find.text('Artifacts 3'));
      await tester.pump();
      expect(find.text('Document'), findsNWidgets(2));
      expect(find.text('Page'), findsOneWidget);
      expect(find.textContaining('new'), findsNothing, reason: 'the first look has no earlier one to compare with');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(MaterialApp(
          home: phone(await installFakes(), Scaffold(body: Row(children: [const Spacer(), AgentPanelDock(seat: seatFromFixture('r-conveyor', 'lead'))])))));
      await tester.pump();
      await tester.tap(find.text('Artifacts 3'));
      await tester.pump();
      expect(find.text('1 new'), findsOneWidget);
      expect(find.text('Document · new'), findsOneWidget);

      await tester.tap(find.text('report.html'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ArtifactViewer), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a dock item opens in the main area beside the open dock; closing it brings back the same child, still mounted',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await pump(tester, PanelPreviewHost(seat: seatFromFixture('r-conveyor', 'lead'), focus: focus, child: Focus(focusNode: focus, autofocus: true, child: const _Live())));
      expect(focus.hasFocus, isTrue);
      final live = tester.state(find.byType(_Live));
      final mainRight = tester.getTopRight(find.byType(_Live)).dx;
      for (final (tab, item, shown) in [('Files 1', 'c.dart', ArtifactViewer), ('Artifacts 3', 'report.html', ArtifactViewer), ('Images 2', 'a.png', MediaViewer)]) {
        await tester.tap(find.text(tab));
        await tester.pump();
        await tester.tap(find.text(item));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(shown), findsOneWidget, reason: '$item opens');
        expect(find.text(tab), findsOneWidget, reason: 'the dock stays open beside it');
        expect(tester.getTopRight(find.byType(shown)).dx, mainRight, reason: 'in the main area, not over the dock');
        expect(find.byType(_Live, skipOffstage: false), findsOneWidget, reason: 'the live child stays mounted');
        expect(focus.hasFocus, isFalse, reason: 'the hidden child takes no keys');
        expect(find.byTooltip('Back'), findsNothing, reason: 'the screen\'s header has the Back: the preview shows no second arrow');
        await Navigator.of(tester.element(find.byType(PanelPreviewHost))).maybePop(); // the header's Back
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        expect(find.byType(shown), findsNothing, reason: 'Back closes it');
        expect(focus.hasFocus, isTrue, reason: 'typing goes on without a click');
        expect(tester.state(find.byType(_Live)), same(live), reason: 'the same live child, not a rebuilt one');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Back with a preview open closes only the preview; the screen goes on the next Back; a preview does not outlive its dock',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final seat = seatFromFixture('r-conveyor', 'lead');
      await pump(tester, PanelPreviewHost(seat: seat, child: const _Live())); // sets up the cache
      // A real route under a real navigator (the pump's pages ignore a pop), as the screen is on the Mac.
      final store = AppScope.of(tester.element(find.byType(PanelPreviewHost)));
      await tester.pumpWidget(AppScope(
          store: store,
          child: MaterialApp(theme: buildTheme(Tokens.light, Brightness.light), home: const SizedBox())));
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: PanelPreviewHost(seat: seat, child: const _Live()))));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Files 1'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('c.dart'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ArtifactViewer), findsOneWidget);
      await nav.maybePop();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byType(ArtifactViewer), findsNothing, reason: 'Back closed the preview');
      expect(find.byType(PanelPreviewHost), findsOneWidget, reason: 'and kept the screen');
      await nav.maybePop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PanelPreviewHost), findsNothing, reason: 'the next Back leaves the screen');

      // A tile that shrinks loses its dock, and the preview with it.
      Widget host(Seat? s) => MaterialApp(home: phone(store, Scaffold(body: PanelPreviewHost(seat: s, child: const _Live()))));
      await tester.pumpWidget(host(seat));
      await tester.pump();
      await tester.tap(find.text('Files 1'));
      await tester.pump();
      await tester.tap(find.text('c.dart'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ArtifactViewer), findsOneWidget);
      await tester.pumpWidget(host(null));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ArtifactViewer), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('with no header Back the preview keeps one arrow, and Escape or that arrow closes only the preview', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final seat = seatFromFixture('r-conveyor', 'lead');
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await pump(tester, PanelPreviewHost(seat: seat, child: const _Live())); // sets up the cache
      final store = AppScope.of(tester.element(find.byType(PanelPreviewHost)));
      Future<void> show() async {
        await tester.pumpWidget(AppScope(
            store: store,
            child: MaterialApp(
                theme: buildTheme(Tokens.light, Brightness.light),
                home: Scaffold(body: PanelPreviewHost(seat: seat, focus: focus, child: Focus(focusNode: focus, autofocus: true, child: const _Live()))))));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.text('Files 1'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('c.dart'));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(ArtifactViewer), findsOneWidget);
      }

      await show();
      expect(find.byTooltip('Back'), findsOneWidget, reason: 'one arrow, so the preview can be closed');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byType(ArtifactViewer), findsNothing, reason: 'Escape closes it');
      expect(find.byType(PanelPreviewHost), findsOneWidget);
      expect(focus.hasFocus, isTrue);
      await show();
      await tester.tap(find.byTooltip('Back'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byType(ArtifactViewer), findsNothing, reason: 'the arrow closes it');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the dock is tabs: Info first, then Files, Images and Artifacts with their counts; it drags wider and hides',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(tester, Row(children: [const Spacer(), AgentPanelDock(seat: seatFromFixture('r-conveyor', 'lead'))]));
      for (final t in ['Info', 'Files 1', 'Images 2', 'Artifacts 3']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('Running here'.toUpperCase()), findsOneWidget, reason: 'Info is the first tab');
      expect(find.text('c.dart'), findsNothing, reason: 'only the open tab is built');

      await tester.tap(find.text('Files 1'));
      await tester.pump();
      expect(find.text('c.dart'), findsOneWidget);
      expect(find.text('notes.md'), findsNothing, reason: 'a Markdown file shows in Artifacts only, not also in Files');
      await tester.tap(find.text('Artifacts 3'));
      await tester.pump();
      expect(find.text('notes.md'), findsOneWidget, reason: 'a card in the Artifacts grid');

      // The dock's left edge drags it wider; the width is kept.
      final left = tester.getTopLeft(find.byType(AgentPanelDock));
      await tester.dragFrom(left + const Offset(2, 200), const Offset(-80, 0));
      await tester.pump();
      expect(agentPanels.value.width, 400);
      expect(tester.getSize(find.byType(AgentPanelDock)).width, 400);

      // The header's toggle (AgentPanelsToggle) is the one Hide panels.
      setAgentPanels(agentPanels.value.copyWith(open: false));
      await tester.pump();
      expect(find.text('Files 1'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  test('a saved layout reads back; an old file with panel orders still loads', () {
    final l = PanelLayout.fromJson(jsonDecode(jsonEncode(const PanelLayout(open: false, width: 500).toJson())) as Map<String, dynamic>);
    expect(l.open, isFalse);
    expect(l.width, 500);
    expect(PanelLayout.fromJson({'width': 5}).width, PanelLayout.minWidth, reason: 'never dragged out of reach');
    expect(PanelLayout.fromJson({'order': ['images'], 'folded': ['files'], 'known': ['images']}).open, isTrue);
  });

  test('artifacts are the documents and pages; File edits keeps code', () {
    final t = DateTime(2026);
    RigMedia f(String path) => RigMedia('file', path, null, t, 'k');
    final all = [f('/w/a.md'), f('/w/b.html'), f('/w/c.dart'), f('/w/d.txt'), f('/w/e.png'), RigMedia('image', '/w/i.png', null, t, 'k')];
    expect(artifactsOf(all).map((m) => m.ref), ['/w/a.md', '/w/b.html', '/w/d.txt']);
    expect(filesOf(all).map((m) => m.ref), ['/w/c.dart', '/w/e.png']);
  });

  testWidgets('the Terminal | Chat switch tells which one shows and fires only for the other side', (tester) async {
    final went = <AgentView>[];
    await tester.pumpWidget(MaterialApp(
        home: Center(child: AgentViewSwitch(showing: AgentView.terminal, onChanged: went.add))));
    await tester.tap(find.text('Terminal'));
    expect(went, isEmpty);
    await tester.tap(find.text('Chat'));
    expect(went, [AgentView.chat]);
    expect(
        find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Terminal' && w.properties.selected == true),
        findsOneWidget);
  });
}

/// Stands for the terminal: a child whose state must survive a preview opening over it.
class _Live extends StatefulWidget {
  const _Live();
  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black, child: SizedBox.expand());
}
