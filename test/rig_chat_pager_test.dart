import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/agent_header.dart';

import 'golden/fixtures.dart';

class _Routes extends NavigatorObserver {
  int pushed = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushed++;
}

/// The seats with nothing waiting on the person, so each page shows its composer.
Object? _quiet(Object? j) => switch (j) {
      List() => [for (final e in j) _quiet(e)],
      Map() => {
          for (final e in j.entries)
            if (e.key != 'needsInputEvidence')
              e.key: switch (e.key) {
                'needsInput' => {'count': 0, 'reason': null},
                'lifecycleState' => 'running',
                'display' => e.value == 'needs-input' ? 'idle' : e.value,
                _ => _quiet(e.value),
              },
        },
      _ => j,
    };

/// conveyor: lead and review run Claude Code (pages), impl and tests run Codex (tabs that open a terminal).
void main() {
  late _Routes routes;
  var nodeCalls = 0;

  Future<void> open(WidgetTester tester) async {
    final store = await installFakes();
    nodeCalls = 0;
    OpenRigClient.factory = (h) {
      final inner = fakeDaemon(h);
      return OpenRigClient(h,
          eventSource: ({rigId, replay, lastEventId}) => const Stream.empty(),
          httpClient: MockClient((req) async {
            if (req.url.path.endsWith('/nodes')) nodeCalls++;
            final res = await inner.get(req.url);
            return req.url.path.endsWith('/nodes') ? http.Response(jsonEncode(_quiet(jsonDecode(res.body))), 200) : res;
          }));
    };
    routes = _Routes();
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [routes],
      home: phone(store, ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true)),
    ));
    // The tabs come from the page's first seat poll, 3 s in.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Lets the log tails and timers wind down, as the other chat tests do.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  String title(WidgetTester tester) => tester.widget<AgentHeader>(find.byType(AgentHeader)).title;
  PageController controller(WidgetTester tester) => tester.widget<PageView>(find.byType(PageView)).controller!;
  List<String> active(WidgetTester tester) =>
      [for (final p in tester.widgetList<ChatPage>(find.byType(ChatPage))) if (p.active) p.seat.logicalId];

  testWidgets('tapping a tab slides to that agent without a new route; the header stays', (tester) async {
    await open(tester);
    expect(title(tester), 'lead');
    expect(find.text('review'), findsWidgets, reason: 'the tab');
    final headers = tester.widgetList(find.byType(AgentHeader)).length;
    final pushedBefore = routes.pushed;

    await tester.tap(find.descendant(of: find.byType(AgentHeader), matching: find.text('review')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final mid = controller(tester).page!;
    expect(mid, inExclusiveRange(0, 1), reason: 'sliding, not jumping');
    await tester.pump(const Duration(seconds: 1));

    expect(controller(tester).page, 1);
    expect(title(tester), 'review');
    expect(routes.pushed, pushedBefore, reason: 'no route pushed');
    expect(tester.widgetList(find.byType(AgentHeader)).length, headers, reason: 'one header for every page');
    await close(tester);
  });

  testWidgets('swiping moves to the neighbour and the header follows', (tester) async {
    await open(tester);
    final pushedBefore = routes.pushed;
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(title(tester), 'review');
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1500);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(title(tester), 'lead');
    expect(routes.pushed, pushedBefore);
    await close(tester);
  });

  testWidgets('only the settled page is active and polls; a neighbour mid-swipe is not', (tester) async {
    await open(tester);
    expect(active(tester), ['lead']);
    // Starts on empty space: a drag that begins on a selectable message belongs to the text (as before).
    final gesture = await tester.startGesture(tester.getTopLeft(find.byType(PageView)) + const Offset(195, 120));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widgetList(find.byType(ChatPage)).length, 2, reason: 'the neighbour is built to slide in');
    expect(active(tester), ['lead'], reason: 'but it stays idle until it has settled');
    await gesture.moveBy(const Offset(-300, 0));
    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(active(tester), ['review']);

    // One seat poll every 3 s, not one per page.
    final before = nodeCalls;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(nodeCalls - before, inInclusiveRange(1, 3), reason: '6 s of one page polling');
    await close(tester);
  });

  testWidgets('a composer draft survives a swipe away and back', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).last, 'half a thought');
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1500);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('half a thought'), findsOneWidget);
    await close(tester);
  });

  testWidgets('swiping away while typing lets the old page go, so typing reaches the agent on screen', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).last, 'for the first agent'); // focuses the composer
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // A focused field keeps its page alive offscreen; only the visible page may remain.
    expect(find.byType(ChatPage, skipOffstage: false), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.context?.widget, isNot(isA<EditableText>()));
    await close(tester);
  });

  testWidgets('a tab for an agent that is not Claude still opens its terminal, replacing the screen', (tester) async {
    await open(tester);
    await tester.tap(find.descendant(of: find.byType(AgentHeader), matching: find.text('impl')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(PageView), findsNothing);
    await close(tester);
  });
}
