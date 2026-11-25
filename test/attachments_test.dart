import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/attachments.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';

void main() {
  final host = Host(id: 'h', name: 'mini', address: 'mini', sshUser: 'me', privateKeyPem: 'k');
  tearDown(() => SshExec.debugConnect = null);

  test('upload names are safe to type into a prompt and never collide in a batch', () {
    final t = DateTime(2026, 11, 2, 9, 5, 7);
    expect(uploadName('Screen Shot (1).png', t), '20261102-090507-Screen_Shot__1_.png');
    expect(uploadName('a.jpg', t, 1), '20261102-090507-1-a.jpg');
    expect(uploadName("\$(rm -rf ~)'", t), '20261102-090507-__rm_-rf____');
    expect(uploadName('', t), '20261102-090507-file');
  });

  test('uploads into the host folder and returns the full paths', () async {
    final commands = <String>[];
    SshExec.debugConnect = (_) async => SshExec.fake((c) async {
          commands.add(c);
          return c.startsWith('mkdir') ? '/Users/me/.cache/pocketrig/uploads\n' : '';
        });
    final paths = await uploadAttachments(host, [('a.png', Uint8List(3)), ('a.png', Uint8List(5))]);
    expect(paths, hasLength(2));
    expect(paths.first, startsWith('/Users/me/.cache/pocketrig/uploads/'));
    expect(paths.toSet(), hasLength(2));
    expect(commands.where((c) => c.startsWith('upload ')).map((c) => c.split(' ').last), ['3', '5']);
  });

  test('a file over the limit is refused before connecting', () async {
    SshExec.debugConnect = (_) async => fail('should not connect');
    await expectLater(uploadAttachments(host, [('big.mov', Uint8List(maxAttachmentBytes + 1))]),
        throwsA(isA<OpenRigException>().having((e) => e.message, 'message', contains('over 50 MB'))));
  });
}
