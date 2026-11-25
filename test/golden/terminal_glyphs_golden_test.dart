// The app's own TerminalStyle (not the demo's) drawing real Claude pane text and the marks agents draw with. The CI image
// draws blocks; goldens/macos (real fonts, main checkout only) is the one that shows the glyphs.
import 'dart:io';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:pocket_rig/ui/terminal_style.dart';
import 'package:xterm/xterm.dart';

String _pane(String name) => File('test/fixtures/panes/$name.txt').readAsStringSync().trimRight();

Widget _terminal(String text, {double height = 330}) {
  final t = Terminal(maxLines: 200)..write(text.replaceAll('\n', '\r\n'));
  return SizedBox(
    width: 560,
    height: height,
    child: ColoredBox(
      color: const Color(0xFF14141A),
      child: TerminalView(t, textStyle: terminalStyle(13), backgroundOpacity: 0, readOnly: true, padding: const EdgeInsets.all(8)),
    ),
  );
}

void main() {
  goldenTest(
    'terminal glyphs: a real Claude pane and the marks agents draw with, in the app\'s TerminalStyle',
    fileName: 'terminal_glyphs',
    pumpBeforeTest: (tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    },
    builder: () => GoldenTestGroup(columns: 1, children: [
      GoldenTestScenario(name: 'permission_bash.txt', child: _terminal(_pane('permission_bash'), height: 330)),
      GoldenTestScenario(name: 'tool_with_tip.txt', child: _terminal(_pane('tool_with_tip'), height: 200)),
      GoldenTestScenario(name: 'marks', child: _terminal('⎿ ✻ ✔ ⏵ ↩ ⋯ ✓ ✗ ※\n⏵⏵ ➜ ✢ ✳ ⌫ ⏴ ⎋ ○ ◐ ◦ ⋮ ⧉', height: 60)),
    ]),
  );
}
