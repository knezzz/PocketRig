/// Modifier keys from the terminal's key bar.
enum TermMod { ctrl, alt, shift }

/// xterm's modifier parameter: 1 + shift + 2·alt + 4·ctrl.
int _param(Set<TermMod> mods) =>
    1 +
    (mods.contains(TermMod.shift) ? 1 : 0) +
    (mods.contains(TermMod.alt) ? 2 : 0) +
    (mods.contains(TermMod.ctrl) ? 4 : 0);

final _csiLetter = RegExp(r'^\x1b\[([A-DHF])$');
final _ss3Letter = RegExp(r'^\x1bO([A-DHF])$');
final _csiTilde = RegExp(r'^\x1b\[(\d+)~$');

/// [data] as it reads with [mods] held, the way xterm encodes it:
/// - arrows, Home/End and PgUp/PgDn get the CSI modifier parameter
///   (Shift+↑ is `ESC[1;2A`);
/// - Shift+Tab is `ESC[Z`, Shift/Alt+Enter is `ESC CR` (a newline in Claude Code);
/// - a letter with Ctrl becomes its control code, with Shift its capital,
///   and Alt puts ESC before it.
/// Anything longer (a paste) goes as it is.
String applyModifiers(String data, Set<TermMod> mods) {
  if (mods.isEmpty || data.isEmpty) return data;
  final ctrl = mods.contains(TermMod.ctrl), alt = mods.contains(TermMod.alt), shift = mods.contains(TermMod.shift);

  if ((_csiLetter.firstMatch(data) ?? _ss3Letter.firstMatch(data)) case final m?) {
    return '\x1b[1;${_param(mods)}${m.group(1)}';
  }
  if (_csiTilde.firstMatch(data) case final m?) return '\x1b[${m.group(1)};${_param(mods)}~';
  if (data == '\t') {
    if (shift) return '\x1b[Z';
    return alt ? '\x1b\t' : data;
  }
  if (data == '\r' || data == '\n') return shift || alt ? '\x1b\r' : data;
  if (data.length != 1) return data;

  var out = data;
  if (shift) out = out.toUpperCase();
  if (ctrl) {
    final c = out.toLowerCase().codeUnitAt(0);
    if (c >= 0x61 && c <= 0x7a) {
      out = String.fromCharCode(c - 0x60);
    } else {
      out = switch (out) {
        ' ' || '@' || '2' => '\x00',
        '[' || '3' => '\x1b',
        '\\' || '4' => '\x1c',
        ']' || '5' => '\x1d',
        '^' || '6' => '\x1e',
        '_' || '-' || '7' => '\x1f',
        '?' || '8' => '\x7f',
        _ => out,
      };
    }
  }
  return alt ? '\x1b$out' : out;
}
