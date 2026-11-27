import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart' show DropItemFile;
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

  test('images upload to the host folder; paths come back as one word list, bare when safe, quoted when not, no Enter', () async {
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
    expect(text, '${paths[0]} ${paths[1]}', reason: 'safe characters only: pasted bare, as a Finder drag does');
    expect(text, isNot(contains('\n')));
    expect(quotedPaths(['/Users/a b/up/x.png', "/a/it's.png", r'/a/$x.png']), r"'/Users/a b/up/x.png' '/a/it'\''s.png' '/a/$x.png'",
        reason: 'quoted only when it needs it');
  });

  test('a file that is not an image refuses the whole drop: nothing is uploaded', () async {
    SshExec.debugConnect = (_) async => fail('should not connect');
    await expectLater(dropImagePaths(host, [('a.png', Uint8List(1)), ('notes.txt', Uint8List(1))]),
        throwsA(isA<OpenRigException>().having((e) => e.message, 'message', contains('notes.txt'))));
    await expectLater(dropImagePaths(host, []), throwsA(isA<OpenRigException>()));
  });

  /// The plugin's drop message, sent in the real-time zone so the target's file read and its 2 s timer run in real time.
  Future<void> drop(WidgetTester tester, List<String> paths) => tester.runAsync(() async {
        const c = StandardMethodCodec();
        final m = tester.binding.defaultBinaryMessenger;
        await m.handlePlatformMessage('desktop_drop', c.encodeMethodCall(const MethodCall('entered', [10.0, 10.0])), (_) {});
        await m.handlePlatformMessage('desktop_drop', c.encodeMethodCall(MethodCall('performOperation', paths)), (_) {});
      }) as Future<void>;

  /// Runs real time (the dropped file is read with real IO) until [done], pumping as it goes; fails if it never is.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 1000 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await tester.pump();
      }
    });
    expect(done(), isTrue, reason: 'it settled');
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
    await drop(tester, [img.path]);
    await settle(tester, () => pasted.isNotEmpty);
    expect(pasted, [
      ['/up/shot.png']
    ]);
    expect(find.text('Attached'), findsOneWidget);
    await settle(tester, () => find.text('Attached').evaluate().isEmpty); // its 2 s run in real time

    fail = true;
    await drop(tester, [img.path]);
    await settle(tester, () => find.textContaining('disk full').evaluate().isNotEmpty);
    expect(pasted, hasLength(1), reason: 'a failed upload pastes nothing');
    await tester.pump(const Duration(seconds: 10));

    fail = false;
    await drop(tester, [txt.path]);
    await settle(tester, () => find.textContaining('a.txt').evaluate().isNotEmpty);
    expect(pasted, hasLength(1));
    await tester.pump(const Duration(seconds: 10));
  });

  test('a drop is checked by name and size before any file is read', () async {
    final big = _Item('/x/movie.png', 51 * 1024 * 1024);
    await expectLater(readDropped([big]), throwsA(isA<OpenRigException>().having((e) => e.message, 'm', contains('over 50 MB'))));
    final video = _Item('/x/movie.mov', 5 * 1024 * 1024 * 1024);
    await expectLater(readDropped([video]), throwsA(isA<OpenRigException>().having((e) => e.message, 'm', contains('isn\'t an image'))));
    expect(big.read, isFalse);
    expect(video.read, isFalse);
    await expectLater(readDropped([_Item('/x/ok.png', 3), big]), throwsA(isA<OpenRigException>()), reason: 'one refused, none read');
    final ok = _Item('/x/ok.png', 3);
    expect((await readDropped([ok])).single.$1, 'ok.png');
  });

  Future<(List<List<String>>, List<int>)> pumpTarget(WidgetTester tester, {Future<List<String>> Function()? hold}) async {
    final store = await installFakes();
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    final pasted = <List<String>>[];
    final uploads = <int>[];
    await tester.pumpWidget(AppScope(
        store: store,
        child: MaterialApp(
            home: ImageDropTarget(
          onPaste: pasted.add,
          upload: (h, files) async {
            uploads.add(files.length);
            return hold != null ? hold() : ['/up/${files.length}.png'];
          },
          child: const SizedBox.expand(),
        ))));
    return (pasted, uploads);
  }

  testWidgets('a dialog over the target takes the drop: nothing is pasted behind it', (tester) async {
    final (pasted, uploads) = await pumpTarget(tester);
    final dir = Directory.systemTemp.createTempSync('drop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final img = File('${dir.path}/shot.png')..writeAsBytesSync([1]);
    showDialog<void>(context: tester.element(find.byType(ImageDropTarget)), builder: (_) => const AlertDialog(title: Text('Sure?')));
    await tester.pumpAndSettle();
    await drop(tester, [img.path]); // the target is off behind the dialog: nothing starts, so nothing to wait for
    await tester.pump();
    expect(pasted, isEmpty);
    expect(uploads, isEmpty);
  });

  testWidgets('a second drop while the first is uploading or showing Attached is ignored', (tester) async {
    final gate = Completer<List<String>>();
    final (pasted, uploads) = await pumpTarget(tester, hold: () => gate.future);
    final dir = Directory.systemTemp.createTempSync('drop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final img = File('${dir.path}/shot.png')..writeAsBytesSync([1]);
    await drop(tester, [img.path]);
    await settle(tester, () => uploads.isNotEmpty); // the file is read, the upload is waiting on the gate
    await drop(tester, [img.path]); // still uploading: ignored before anything is read
    await tester.pump();
    expect(uploads, hasLength(1));
    gate.complete(['/up/a.png']);
    await settle(tester, () => find.text('Attached').evaluate().isNotEmpty);
    await drop(tester, [img.path]); // Attached is showing: ignored
    await tester.pump();
    expect(uploads, hasLength(1));
    expect(pasted, hasLength(1));
    await settle(tester, () => find.text('Attached').evaluate().isEmpty);
    await drop(tester, [img.path]); // idle again: the next drop goes
    await settle(tester, () => uploads.length == 2);
    await settle(tester, () => find.text('Attached').evaluate().isEmpty);
  });
}

/// A dropped file that reports a size and fails if its bytes are read.
class _Item extends DropItemFile {
  _Item(super.path, this.size);
  final int size;
  var read = false;
  @override
  Future<int> length() async => size;
  @override
  Future<Uint8List> readAsBytes() async {
    read = true;
    return Uint8List(0);
  }
}
