import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat/draw_screen.dart';

import 'golden/fixtures.dart';

/// A 1×1 PNG.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');

void main() {
  testWidgets('a drawing goes to the host as a PNG and its path, after the note, into the agent', (tester) async {
    final store = await installFakes();
    final ran = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((c) async {
          ran.add(c);
          return c.contains('send-keys') ? 'POCKETRIG_SENT' : (c.startsWith('mkdir') ? '/home/u/up' : fakeShell(c));
        });
    addTearDown(() => SshExec.debugConnect = null);
    final seat = Seat(rigId: '', logicalId: 'scratch', sessionName: 'scratch', runtime: 'claude-code');
    await tester.pumpWidget(MaterialApp(home: phone(store, DrawScreen(image: _png, name: 'shot.png', seat: seat))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200))); // decode
    await tester.pump();
    final canvas = find.byType(CustomPaint).last;
    await tester.drag(canvas, const Offset(40, 0));
    await tester.pump();
    expect(find.byTooltip('Undo'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'circled');
    await tester.runAsync(() async {
      await tester.tap(find.text('Send'));
      // Real time: wait for the upload and the send, not a fixed 500ms, which a busy machine overruns.
      for (var i = 0; i < 100 && !ran.any((c) => c.contains('send-keys')); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pump();
    final upload = ran.firstWhere((c) => c.startsWith('upload '));
    expect(upload, matches(RegExp(r'^upload /home/u/up/\d{8}-\d{6}-shot-drawn\.png \d+$')));
    final path = upload.split(' ')[1];
    expect(ran.where((c) => c.contains('send-keys') && c.contains("'circled $path'")), hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
