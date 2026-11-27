import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ui/host_color.dart';
import 'package:pocket_rig/ui/theme.dart';

void main() {
  test('a host keeps the color picked for it; without one, its id fixes one from the palette', () {
    Host h(String id, [int? color]) => Host(id: id, name: 'n', address: 'a', sshUser: 'u', color: color);
    expect(hostColor(h('mini')), hostColor(h('mini')), reason: 'stable across runs');
    expect(hostPalette, contains(hostColor(h('mini'))));
    final picked = hostPalette[3].toARGB32();
    expect(hostColor(Host.fromJson(h('mini', picked).toJson())), hostPalette[3]);
    expect(Host.fromJson(h('mini').toJson()).color, isNull);
  });

  testWidgets('the overline leads with the host name in its color', (tester) async {
    final host = Host(id: 'h', name: 'mini', address: 'a', sshUser: 'u', color: hostPalette[1].toARGB32());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: hostOverline(host, null, rest: 'app'))));
    expect(find.text('mini · app'), findsOneWidget);
    final span = (tester.widget<Text>(find.text('mini · app')).textSpan! as TextSpan).children!.first as TextSpan;
    expect(span.style?.color, hostPalette[1]);
  });

  test('a colour too close to the ground is pulled in lightness to 4.5:1, keeping its hue; a readable one is left alone', () {
    const near = Color(0xFFF2F2D8); // pale yellow-grey on the light ground
    final light = readableOn(near, Tokens.light.ground);
    expect(contrastRatio(light, Tokens.light.ground), greaterThanOrEqualTo(4.5));
    expect((HSLColor.fromColor(light).hue - HSLColor.fromColor(near).hue).abs(), lessThan(3), reason: 'same hue');
    expect(HSLColor.fromColor(light).lightness, lessThan(HSLColor.fromColor(near).lightness), reason: 'darkened on a light ground');

    const dim = Color(0xFF2A2F6B); // deep indigo on the dark ground
    final dark = readableOn(dim, Tokens.dark.ground);
    expect(contrastRatio(dark, Tokens.dark.ground), greaterThanOrEqualTo(4.5));
    expect(HSLColor.fromColor(dark).lightness, greaterThan(HSLColor.fromColor(dim).lightness), reason: 'lightened on a dark ground');

    const fine = Color(0xFFC2185B);
    expect(readableOn(fine, Tokens.light.ground), fine);
    for (final k in [Tokens.light, Tokens.dark]) {
      for (final c in [...hostPalette, Colors.white, Colors.black, const Color(0xFF808080)]) {
        expect(contrastRatio(readableOn(c, k.ground), k.ground), greaterThanOrEqualTo(4.5), reason: '$c on ${k.isDark ? 'dark' : 'light'}');
      }
    }
  });

  test('a custom colour is saved with the host and read back as it was', () {
    final host = Host(id: 'h', name: 'n', address: 'a', sshUser: 'u', color: 0xFF1E88E5);
    expect(hostColor(Host.fromJson(host.toJson())), const Color(0xFF1E88E5));
  });

  test('on the dark ground every palette colour reaches 3:1, and the saved value is unchanged', () {
    const k = Tokens.dark;
    for (final c in hostPalette) {
      final h = Host(id: 'x', name: 'n', address: 'a', sshUser: 'u', color: c.toARGB32());
      expect(contrastRatio(hostColor(h, k), k.ground), greaterThanOrEqualTo(3), reason: '$c');
      expect(h.color, c.toARGB32());
    }
  });

  test('dark faint is 3:1 on ground and on fill', () {
    const k = Tokens.dark;
    expect(contrastRatio(k.faint, k.ground), greaterThanOrEqualTo(3));
    expect(contrastRatio(k.faint, k.fill), greaterThanOrEqualTo(3));
  });
}
