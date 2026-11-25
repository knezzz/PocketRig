import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the mouse-vs-finger rule is navMouse() (kit.dart), not written out again', () {
    final inline = RegExp(r'isDesktop\s*\|\|\s*WidgetsBinding\.instance\.mouseTracker\.mouseIsConnected');
    final copies = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') && !f.path.endsWith('ui/kit.dart') && inline.hasMatch(f.readAsStringSync())) f.path
    ];
    expect(copies, isEmpty);
  });
}
