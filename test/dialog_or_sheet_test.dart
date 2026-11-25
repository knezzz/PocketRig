import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/ui/hosts/colour_picker.dart' show pickCustomColour;
import 'package:pocket_rig/ui/kit.dart' show showDialogOrSheet;

void main() {
  Future<void> open(WidgetTester tester, Future<void> Function(BuildContext) go) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => go(c), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the Mac gets one square Dialog of at most maxWidth; a phone gets a drag-handle sheet that keeps clear of the notch', (tester) async {
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    await open(tester, (c) => showDialogOrSheet<void>(c, child: const SizedBox(key: ValueKey('body'), width: double.infinity, height: 100), maxWidth: 400));
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.shape, isA<RoundedRectangleBorder>().having((s) => s.borderRadius, 'square', BorderRadius.zero));
    expect(tester.getSize(find.byKey(const ValueKey('body'))).width, 400, reason: 'at most the max width');
    expect(find.byType(BottomSheet), findsNothing);
    Navigator.of(tester.element(find.byType(Dialog))).pop();
    await tester.pumpAndSettle();

    isDesktop = false;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.showDragHandle, isTrue);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('the colour picker follows the same rule: a dialog on the Mac, a sheet on a phone, a mouse or not', (tester) async {
    isDesktop = false;
    await open(tester, (c) => pickCustomColour(c, initial: Colors.red, hostName: 'homelab'));
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
  });
}
