import 'package:flutter_test/flutter_test.dart';

/// Sets a project or rig row's view ('Show all', 'Show active only' or 'Fold') through its long-press list: the row has
/// no chevron, so this list is its control.
Future<void> chooseView(WidgetTester tester, Finder row, String choice) async {
  await tester.longPress(row);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text(choice));
  await tester.pump(const Duration(milliseconds: 400));
}
