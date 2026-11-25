import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/openrig_client.dart';
import 'package:pocket_rig/data/fleet.dart' show fleet;
import 'package:pocket_rig/data/prompt_screen.dart';
import 'package:pocket_rig/models.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';

import 'golden/fixtures.dart';

String pane(String name) => File('test/fixtures/panes/$name.txt').readAsStringSync();

void main() {
  test('a screen shows a dialog when it lists numbered choices; an idle or empty one shows none', () {
    expect(noDialogOnScreen(pane('permission')), isFalse);
    // Real screens from a Claude Code 2.1.329 session: each must stay waiting.
    for (final real in ['permission_bash', 'question', 'question_option2', 'trust']) {
      expect(noDialogOnScreen(pane(real)), isFalse, reason: real);
    }
    expect(noDialogOnScreen(pane('idle')), isTrue);
    expect(noDialogOnScreen(pane('tool_running')), isTrue);
    expect(noDialogOnScreen(''), isFalse, reason: 'a failed read proves nothing');
    expect(noDialogOnScreen('  \n'), isFalse);
    expect(noDialogOnScreen('Plan:\n  1. First step\n'), isFalse, reason: 'a numbered list is taken for a dialog');
  });

  test('the screens script names each session and the parser keeps those without a dialog', () {
    final script = screensScript(['a@r', "it's@r"]);
    expect(script, contains("tmux capture-pane -p -t '=a@r:'"));
    expect(script, contains(r"'it'\''s@r'"));
    final out = '@@screen\ta@r\n${pane('idle')}@@screen\tb@r\n${pane('permission')}@@screen\tc@r\n';
    expect(sessionsWithoutDialog(out), {'a@r'});
  });

  /// conveyor's `review` seat is working and the daemon says it asks for permission; its screen is [screen].
  Future<Seat> reviewWith(String screen, {bool local = false}) async {
    final store = await installFakes();
    final shell = SshExec.debugConnect!;
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async {
          if (cmd.contains('@@screen')) return '@@screen\treview@conveyor\n$screen';
          return (await shell(h)).run(cmd);
        });
    OpenRigClient.factory = (h) {
      final inner = fakeDaemon(homelab); // whichever host asks, the conveyor rig answers
      return OpenRigClient(h,
          eventSource: ({rigId, replay, lastEventId}) => const Stream.empty(),
          httpClient: MockClient((req) async {
            final res = await inner.get(req.url);
            if (!req.url.path.endsWith('/nodes')) return res;
            Object? edit(Object? j) => switch (j) {
                  List() => [for (final e in j) edit(e)],
                  Map() when j['logicalId'] == 'review' => {
                      ...j,
                      'activityState': {
                        'activity': 'working',
                        'display': 'needs-input',
                        'needsInput': {'count': 1, 'reason': 'permission_prompt'},
                      },
                    },
                  Map() => {for (final e in j.entries) e.key: edit(e.value)},
                  _ => j,
                };
            return http.Response(jsonEncode(edit(jsonDecode(res.body))), 200);
          }));
    };
    homelab.privateKeyPem = 'PEM';
    addTearDown(() => homelab.privateKeyPem = null);
    // This Mac has no key: its commands run in a local shell.
    final host = local ? Host.local('me') : store.active!;
    if (local) {
      homelab.privateKeyPem = null;
      await store.upsert(host);
    }
    final feed = fleet.feedFor(host);
    await feed.refresh();
    return feed.rigs.expand((r) => r.seats).firstWhere((s) => s.logicalId == 'review');
  }

  test('the daemon holds an ask for a dialog nobody sees: the seat is not waiting while its screen shows none', () async {
    final seat = await reviewWith(pane('idle'));
    expect(seat.daemonAsks, isTrue, reason: 'the daemon still says it asks');
    expect(seat.needsInput, isFalse);
    expect(seat.state, isNot(SeatState.needsYou));
    expect(fleet.feedFor(homelab).needsYouItems.where((i) => i.seat?.logicalId == 'review'), isEmpty);
  });

  test('a real dialog on the screen keeps the seat waiting', () async {
    final seat = await reviewWith(pane('permission'));
    expect(seat.needsInput, isTrue);
    expect(seat.state, SeatState.needsYou);
  });

  test('This Mac, which has no key and runs commands locally, reads its screens too', () async {
    final seat = await reviewWith(pane('idle'), local: true);
    expect(seat.daemonAsks, isTrue);
    expect(seat.needsInput, isFalse);
  });

  test('real dialogs keep the seat waiting, including one without numbers', () async {
    for (final real in ['permission_bash', 'question', 'question_option2', 'trust']) {
      final seat = await reviewWith(pane(real));
      expect(seat.needsInput, isTrue, reason: real);
    }
  });

  test('an unreadable screen leaves the daemon\'s word standing', () async {
    final seat = await reviewWith('');
    expect(seat.needsInput, isTrue);
  });
}
