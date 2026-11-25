import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/chat_cache.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/agent_panels.dart';

RigMedia _doc(String name, DateTime at) => RigMedia('file', '/w/$name', null, at, 'k');

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: SizedBox(width: 360, height: 600, child: child)));

void main() {
  testWidgets('the dock and the phone sheet share their panel bodies: same empty words, same "N new" for artifacts', (tester) async {
    final old = _doc('old.md', DateTime(2026, 1, 1)), fresh = _doc('plan.md', DateTime(2026, 1, 3));
    final since = DateTime(2026, 1, 2);
    await tester.pumpWidget(_host(PanelArtifacts(docs: [fresh, old], cwd: '/w', newSince: since)));
    expect(find.text('1 new'), findsOneWidget, reason: 'only what was written after the panels were last shown');
    expect(find.text('Document · new'), findsOneWidget);
    for (final dense in [true, false]) {
      await tester.pumpWidget(_host(PanelArtifacts(docs: const [], cwd: null, dense: dense)));
      expect(find.text('No documents or pages yet'), findsOneWidget, reason: 'dense: $dense');
      await tester.pumpWidget(_host(PanelFiles(files: const [], cwd: null, onOpen: (_) {}, dense: dense)));
      expect(find.text('No files changed yet'), findsOneWidget);
      await tester.pumpWidget(_host(PanelImages(images: const [], onOpen: (_) {}, dense: dense)));
      expect(find.text('No images yet'), findsOneWidget);
    }
  });

  testWidgets('files: a row each with the path under the checkout, a tap opens it', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(_host(PanelFiles(
        files: [RigMedia('file', '/w/lib/a.dart', null, DateTime(2026), 'k')], cwd: '/w', onOpen: (m) => opened.add(m.ref))));
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.text('lib/a.dart'), findsOneWidget);
    await tester.tap(find.text('a.dart'));
    expect(opened, ['/w/lib/a.dart']);
  });

  test('the panels\' "last shown" time is read and renewed together, for the dock and the sheet alike', () {
    final seat = Seat(rigId: 'r', logicalId: 'x', sessionName: 'x@r', runtime: 'claude-code');
    expect(takePanelsOpenedAt(seat), isNull, reason: 'the first time nothing is new');
    final second = takePanelsOpenedAt(seat);
    expect(second, isNotNull);
    expect(DateTime.now().difference(second!), lessThan(const Duration(seconds: 5)));
  });

  test('one rule for what the Images panel lists', () {
    expect(isPanelMedia(RigMedia('image', 'a.png', null, DateTime(2026), 'k')), isTrue);
    expect(isPanelMedia(RigMedia('video', 'a.mp4', null, DateTime(2026), 'k')), isTrue);
    expect(isPanelMedia(RigMedia('file', 'a.dart', null, DateTime(2026), 'k')), isFalse);
  });
}
