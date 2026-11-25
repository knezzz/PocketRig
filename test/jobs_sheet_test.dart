import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/agent_jobs.dart';
import 'package:pocket_rig/main.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat/jobs_view.dart';

import 'golden/fixtures.dart';

void main() {
  testWidgets('with many shells the sheet leaves the scrim showing, so a tap outside closes it', (tester) async {
    final store = await installFakes();
    final out = [
      for (var i = 1; i <= 40; i++)
        "J\t$i\tS\t01:00\t0\t0\tzsh -c source /h/shell-snapshots/s.sh && eval 'sleep $i' < /dev/null && pwd -P >| /tmp/x",
    ].join('\n');
    final jobs = AgentJob.parse(out);
    SshExec.debugConnect = (h) async => SshExec.fake((cmd) async => out); // the 3 s refresh must return the same 40
    await tester.pumpWidget(AppScope(
      store: store,
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(onPressed: () => showJobsSheet(context, jobs, 'impl@app', (_) {}), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Running processes'), findsOneWidget);

    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.text('Running processes'), findsNothing);
  });
}
