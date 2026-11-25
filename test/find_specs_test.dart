import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';

/// Runs the spec search on a real shell, in [dir], as findRigSpecs does over SSH.
List<String> findIn(Directory dir) {
  final r = Process.runSync('sh', ['-c', 'cd "\$1" && ${SshExec.findSpecsScript}', 'sh', dir.path]);
  // find prints "$PWD/<rel>"; PWD is the path as cd was given it.
  return [
    for (final l in (r.stdout as String).split('\n'))
      if (l.trim().isNotEmpty) l.substring(dir.path.length + 1)
  ]..sort();
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pocketrig-specs-'));
  tearDown(() => dir.deleteSync(recursive: true));

  void write(String rel, String text) =>
      (File('${dir.path}/$rel')..createSync(recursive: true)).writeAsStringSync(text);
  const spec = 'version: "0.2"\nname: simple\n\npods:\n  - id: orch\n';

  test('readFile reports a file it cannot read instead of showing it empty', () async {
    final ssh = SshExec.fake((c) async => Process.runSync('sh', ['-c', c]).stdout as String);
    write('empty.txt', '');
    expect(await ssh.readFile('${dir.path}/empty.txt'), '');
    await expectLater(ssh.readFile('${dir.path}/gone.dart'),
        throwsA(isA<OpenRigException>().having((e) => '$e', 'message', contains('No such file or directory'))));
  });

  test('rig specs are found past hundreds of other YAML files', () {
    // Maestro flows sort before rigs/ and used to fill the 400-file cap first.
    for (var i = 0; i < 450; i++) {
      write('.maestro/flows/flow_$i.yaml', 'appId: com.example\n---\n- launchApp\n');
    }
    write('rigs/simple/rig.yaml', spec);
    write('rigs/full/rig.yml', spec.replaceFirst('simple', 'full'));
    write('pubspec.yaml', 'name: app\n');
    write('node_modules/x/rig.yaml', spec);
    write('build/out/rig.yaml', spec);
    write('notes/indented.yaml', 'meta:\n  name: x\n  pods: []\n');
    expect(findIn(dir), ['rigs/full/rig.yml', 'rigs/simple/rig.yaml']);
  });

  test('a folder with no specs finds nothing', () {
    write('pubspec.yaml', 'name: app\n');
    expect(findIn(dir), isEmpty);
  });

  // findRigSpecs end to end, its commands run by a real shell.
  final shell = SshExec.fake((cmd) async => (Process.runSync('sh', ['-c', cmd]).stdout as String));

  test('specs are listed with the folder as their project', () async {
    write('rigs/simple/rig.yaml', spec);
    final found = await shell.findRigSpecs(dir.path);
    expect(found.map((f) => f.relativePath), ['rigs/simple/rig.yaml']);
  });

  test('a folder find may not read is reported, not shown as "no specs"', () async {
    write('pubspec.yaml', 'name: app\n');
    final locked = Directory('${dir.path}/locked')..createSync();
    File('${locked.path}/rig.yaml').writeAsStringSync(spec);
    Process.runSync('chmod', ['000', locked.path]);
    addTearDown(() => Process.runSync('chmod', ['755', locked.path]));
    expect(
        shell.findRigSpecs(dir.path),
        throwsA(isA<OpenRigException>().having((e) => e.message, 'message',
            allOf(contains("didn't let SSH read 1 folder"), contains('Allow full disk access for remote users')))));

    // A spec found elsewhere still lists; the blocked folder doesn't hide it.
    write('rigs/simple/rig.yaml', spec);
    expect((await shell.findRigSpecs(dir.path)).map((f) => f.relativePath), ['rigs/simple/rig.yaml']);
  });

  test('a folder that is not there says so', () {
    expect(shell.findRigSpecs('${dir.path}/nope'),
        throwsA(isA<OpenRigException>().having((e) => e.message, 'message', contains("Couldn't open"))));
  });
}
