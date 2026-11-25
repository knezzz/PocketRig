import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/terminal_style.dart';

void main() {
  test('the terminal style puts our two glyph fonts first, then xterm\'s defaults, one style for every terminal', () {
    final s = terminalStyle(12);
    expect(s.fontFamily, 'JetBrains Mono');
    expect(s.fontFamilyFallback.take(2), ['PocketRig Glyphs', 'PocketRig Emoji']);
    expect(s.fontFamilyFallback, containsAllInOrder(['PocketRig Glyphs', 'Menlo', 'Noto Color Emoji', 'sans-serif']));
    expect(s.fontSize, 12);
  });

  test('the fonts are bundled, registered in pubspec and small, with their licence next to them', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final (family, file) in [('PocketRig Glyphs', 'PocketRigGlyphs.ttf'), ('PocketRig Emoji', 'PocketRigEmoji.ttf')]) {
      expect(pubspec, contains('family: $family'));
      expect(pubspec, contains('assets/fonts/$file'));
      expect(File('assets/fonts/$file').lengthSync(), inInclusiveRange(1000, 150 * 1024), reason: '$file is a subset, not a whole font');
    }
    expect(File('assets/fonts/OFL-NotoGlyphs.txt').readAsStringSync(), contains('SIL OPEN FONT LICENSE'));
  });
}
