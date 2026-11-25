import 'package:xterm/xterm.dart';

import 'theme.dart' show fontMono;

/// xterm's own fallback families (its default list is private), kept after ours.
const _xtermFallbacks = [
  'Menlo',
  'Monaco',
  'Consolas',
  'Liberation Mono',
  'Courier New',
  'Noto Sans Mono CJK SC',
  'Noto Sans Mono CJK TC',
  'Noto Sans Mono CJK KR',
  'Noto Sans Mono CJK JP',
  'Noto Sans Mono CJK HK',
  'Noto Color Emoji',
  'Noto Sans Symbols',
  'monospace',
  'sans-serif',
];

/// The one terminal text style (the single terminal and the tiles). JetBrains Mono has no braille (U+2800-28FF: the spinners)
/// and no ⏺ U+23FA, ⏸ U+23F8 or ✨ U+2728, which fall to a system font that differs by platform (tofu on iOS; on the Mac colour
/// emoji wider than a cell and braille with every dot drawn). Our two small fonts come first, so they draw the same
/// everywhere, one cell each (the sparkles two); xterm's defaults follow for anything else.
TerminalStyle terminalStyle(double size) => TerminalStyle(
      fontSize: size,
      fontFamily: fontMono,
      fontFamilyFallback: const ['PocketRig Glyphs', 'PocketRig Emoji', ..._xtermFallbacks],
    );
