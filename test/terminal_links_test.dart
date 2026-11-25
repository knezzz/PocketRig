import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/terminal/links.dart';

void main() {
  test('the link under the click, without trailing punctuation; tmux-split rows join', () {
    expect(linkInRows(['see https://openrig.dev/help. ok'], 40, 0, 10), 'https://openrig.dev/help');
    expect(linkInRows(['see https://openrig.dev/help. ok'], 40, 0, 2), isNull, reason: 'not on the link');
    expect(linkInRows(['see https://openrig.dev/help. ok'], 40, 0, 28), isNull, reason: 'on the full stop');
    expect(linkInRows(['(https://a.dev/x) and'], 30, 0, 5), 'https://a.dev/x');
    // A 20-column pane: the link fills row 0 and carries on in row 1; a click on either half opens it whole.
    final rows = ['go https://ex.com/ab', 'cdef then', 'next'];
    expect(linkInRows(rows, 20, 1, 2), 'https://ex.com/abcdef');
    expect(linkInRows(rows, 20, 0, 5), 'https://ex.com/abcdef');
    expect(linkInRows(rows, 20, 2, 1), isNull);
  });
}
