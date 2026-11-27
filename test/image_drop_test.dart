import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/host_store.dart' show isDesktop;
import 'package:pocket_rig/main.dart' show AppScope;
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/file_drop.dart';

import 'golden/fixtures.dart';

void main() {
  final host = Host(id: 'h', name: 'mini', address: 'mini', sshUser: 'me', privateKeyPem: 'k');
  tearDown(() => SshExec.debugConnect = null);

  test('images upload to the host folder; paths are quoted for the shell, one word list, no Enter', () async {
    final commands = <String>[];
    SshExec.debugConnect = (_) async => SshExec.fake((c) async {
          commands.add(c);
          return c.startsWith('mkdir') ? '/Users/me/.cache/pocketrig/uploads\n' : '';
        });
    final paths = await dropImagePaths(host, [('Screen Shot.PNG', Uint8List(3)), ('b.webp', Uint8List(5))]);
    expect(paths, hasLength(2));
    expect(paths.first, startsWith('/Users/me/.cache/pocketrig/uploads/'));
    expect(commands.where((c) => c.startsWith('upload ')), hasLength(2));
    final text = quotedPaths(paths);
    expect(text, "'${paths[0]}' '${paths[1]}'");
    expect(text, isNot(contains('\n')));
    expect(quotedPaths(["/a/it's.png"]), r"'/a/it'\''s.png'");
  });

  test('a file that is not an image refuses the whole drop: nothing is uploaded', () async {
    SshExec.debugConnect = (_) async => fail('should not connect');
    await expectLater(dropImagePaths(host, [('a.png', Uint8List(1)), ('notes.txt', Uint8List(1))]),
        throwsA(isA<OpenRigException>().having((e) => e.message, 'message', contains('notes.txt'))));
    await expectLater(dropImagePaths(host, []), throwsA(isA<OpenRigException>()));
  });

  Future<void> drop(WidgetTester tester, List<String> paths) async {
    final c = const StandardMethodCodec();
    final m = tester.binding.defaultBinaryMessenger;
    await m.handlePlatformMessage('desktop_drop', c.encodeMethodCall(const MethodCall('entered', [10.0, 10.0])), (_) {});
    await m.handlePlatformMessage('desktop_drop', c.encodeMethodCall(MethodCall('performOperation', paths)), (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 200)); // the file read is real IO
  }

  testWidgets('dropping a file on the target uploads it and pastes the path; a failure pastes nothing', (tester) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    final dir = Directory.systemTemp.createTempSync('drop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final img = File('${dir.path}/shot.png')..writeAsBytesSync([1, 2, 3]);
    final txt = File('${dir.path}/a.txt')..writeAsStringSync('x');
    final pasted = <List<String>>[];
    var fail = false;
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(
            home: ImageDropTarget(
          onPaste: pasted.add,
          upload: (h, files) async {
            if (fail) throw OpenRigException('disk full');
            expect(files.single.$1, 'shot.png');
            expect(files.single.$2, [1, 2, 3]);
            return ['/up/shot.png'];
          },
          child: const SizedBox.expand(),
        ))));
    await tester.runAsync(() => drop(tester, [img.path]));
    await tester.pump();
    expect(pasted, [
      ['/up/shot.png']
    ]);
    expect(find.text('Attached'), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2100))); // the drop ran in real time
    await tester.pump();
    expect(find.text('Attached'), findsNothing);

    fail = true;
    await tester.runAsync(() => drop(tester, [img.path]));
    await tester.pump();
    expect(find.textContaining('disk full'), findsOneWidget, reason: 'it says why');
    expect(pasted, hasLength(1), reason: 'a failed upload pastes nothing');
    await tester.pump(const Duration(seconds: 10));

    fail = false;
    await tester.runAsync(() => drop(tester, [txt.path]));
    await tester.pump();
    expect(find.textContaining('a.txt'), findsOneWidget);
    expect(pasted, hasLength(1));
    await tester.pump(const Duration(seconds: 10));
  });
}
