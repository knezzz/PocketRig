import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/terminal/transport.dart';
import 'package:pocket_rig/ui/terminal_screen.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('a project shell\'s ⋯ lists Reflow, Reconnect, Copy path, Rename and Close shell; Close shell asks, ends the session and leaves the screen',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = await installFakes();
    final ran = <String>[];
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          ran.add(cmd);
          return cmd.contains('kill-session') ? 'pocketrig-closed\n' : await fakeShell(cmd);
        });
    addTearDown(() => SshExec.debugConnect = null);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(MaterialApp(
      home: phone(
        store,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TerminalScreen(target: ProjectShellTarget('/Users/me/code/app')))),
                child: const Text('open shell'),
              ),
            ),
          ),
        ),
        root: true,
      ),
    ));
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.text('open shell'));
    await settle();
    await tester.tap(find.byTooltip('Seat options'));
    await tester.pumpAndSettle();
    for (final item in ['Reflow', 'Reconnect', 'Copy path', 'Rename…', 'Close shell…']) {
      expect(find.text(item), findsOneWidget, reason: item);
    }
    expect(find.text('Chat'), findsNothing, reason: 'a shell has no chat');

    await tester.tap(find.text('Copy path'));
    await tester.pumpAndSettle();
    expect(copied, '/Users/me/code/app');

    await tester.tap(find.byTooltip('Seat options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close shell…'));
    await tester.pumpAndSettle();
    expect(find.text('Close rp-app?'), findsOneWidget);
    expect(ran.where((c) => c.contains('kill-session')), isEmpty, reason: 'not before the confirm');
    await tester.tap(find.text('Close shell'));
    await tester.pumpAndSettle();
    expect(ran.where((c) => c.contains('kill-session') && c.contains('=rp-app')), hasLength(1));
    expect(find.byType(TerminalScreen), findsNothing, reason: 'the screen is gone with its shell');
    expect(find.text('open shell'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
