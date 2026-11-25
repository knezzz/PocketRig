import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/ux_log.dart';

void main() {
  test('findings flag rage taps, crashes, error toasts, quick back-outs and repeated slow calls', () {
    final ev = [
      UxEvent('open', 'ChatScreen'),
      UxEvent('rage', 'ChatScreen', '10,10'),
      UxEvent('rage', 'ChatScreen', '10,10'),
      UxEvent('error', 'RigScreen', 'boom'),
      UxEvent('toast', 'Hosts', "Couldn't reach host"),
      UxEvent('toast', 'Hosts', 'Copied'),
      UxEvent('open', 'SpecScreen'),
      UxEvent('close', 'SpecScreen', '800'),
      UxEvent('open', 'SpecScreen'),
      UxEvent('close', 'SpecScreen', '1200'),
      UxEvent('open', 'SpecScreen'),
      UxEvent('close', 'SpecScreen', '9000'),
      UxEvent('call', 'Projects', 'GET /api/rigs 2400ms 200'),
      UxEvent('call', 'Projects', 'GET /api/rigs 0ms 502'),
      UxEvent('call', 'Projects', 'GET /api/other 3000ms 200'),
    ];
    final f = findings(ev);
    expect(f, hasLength(5));
    expect(f.first, startsWith('2 rage taps on ChatScreen'));
    expect(f, contains('1 crash on RigScreen.'));
    expect(f, contains('1 error message shown on Hosts.'));
    expect(f, contains(startsWith('SpecScreen closed within 2 s 2 times of 3')));
    expect(f, contains('GET /api/rigs was slow or failed 2 times.'));

    final spec = screenStats(ev).firstWhere((s) => s.name == 'SpecScreen');
    expect(spec.visits, 3);
    expect(spec.medianSeconds, 1.2);
  });

  test('a clean log flags nothing', () {
    expect(findings([UxEvent('open', 'Projects'), UxEvent('tap', 'Projects', '1,1')]), isEmpty);
  });

  testWidgets('taps on the app count; taps on a panel stacked above it do not', (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(children: [
        UxTaps(child: SizedBox.expand()),
        Positioned(left: 0, top: 0, width: 100, height: 100, child: ColoredBox(color: Color(0xFF000000))),
      ]),
    ));
    int taps() => uxLog.events.where((e) => e.kind == 'tap').length;
    final before = taps();
    await tester.tapAt(const Offset(50, 50)); // the panel
    expect(taps(), before);
    await tester.tapAt(const Offset(300, 300)); // the app
    expect(taps(), before + 1);
  });

  testWidgets('pushed screens are named after their screen widget and timed', (tester) async {
    final key = GlobalKey<NavigatorState>();
    final obs = UxRouteObserver();
    await tester.pumpWidget(MaterialApp(navigatorKey: key, navigatorObservers: [obs], home: const SizedBox()));
    key.currentState!.push(MaterialPageRoute<void>(builder: (_) => const FakeSettingsScreen()));
    await tester.pumpAndSettle();
    expect(uxLog.screen, 'FakeSettingsScreen');
    key.currentState!.pop();
    await tester.pumpAndSettle();
    final close = uxLog.events.lastWhere((e) => e.kind == 'close');
    expect(close.screen, 'FakeSettingsScreen');
    expect(uxLog.screen, 'Projects');
  });
}

class FakeSettingsScreen extends StatelessWidget {
  const FakeSettingsScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('x'));
}
