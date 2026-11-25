import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';

final _url = RegExp(r'''https?://[^\s<>"'`]+''');

/// The link under column [x] of row [y] in [rows] (each [width] columns). tmux redraws a long link as separate full
/// rows, so a row that runs to the right edge carries on into the next one.
/// shortcut: counts one column per character, so a wide character (CJK, emoji) earlier on the row shifts the hit.
String? linkInRows(List<String> rows, int width, int y, int x) {
  if (y < 0 || y >= rows.length) return null;
  bool full(int i) => rows[i].length >= width && rows[i].trimRight().length >= width;
  var first = y, last = y;
  while (first > 0 && full(first - 1)) {
    first--;
  }
  while (last < rows.length - 1 && full(last)) {
    last++;
  }
  final text = StringBuffer();
  var at = 0;
  for (var i = first; i <= last; i++) {
    if (i == y) at = text.length + x;
    text.write(i < last ? rows[i].padRight(width).substring(0, width) : rows[i]);
  }
  for (final m in _url.allMatches(text.toString())) {
    if (at < m.start || at >= m.end) continue;
    var link = m[0]!;
    // Sentence punctuation after a link, and a closing bracket it didn't open.
    while (link.isNotEmpty &&
        ('.,;:!?'.contains(link[link.length - 1]) || (link.endsWith(')') && !link.contains('(')))) {
      link = link.substring(0, link.length - 1);
    }
    return at < m.start + link.length ? link : null;
  }
  return null;
}

/// TerminalView's onTapUp: ⌘+click on a Mac (Ctrl+click elsewhere) on a link opens it in the browser.
void openLinkOnModClick(Terminal terminal, TapUpDetails _, CellOffset cell) {
  final keys = HardwareKeyboard.instance;
  if (!(Platform.isMacOS ? keys.isMetaPressed : keys.isControlPressed)) return;
  final lines = terminal.buffer.lines;
  final rows = [for (var i = 0; i < lines.length; i++) lines[i].getText()];
  final link = linkInRows(rows, terminal.viewWidth, cell.y, cell.x);
  if (Uri.tryParse(link ?? '') case final uri? when link != null) launchUrl(uri, mode: LaunchMode.externalApplication);
}
