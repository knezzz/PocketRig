import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/app_icon.dart';
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, List<Widget> icons) => tester.pumpWidget(MaterialApp(
        theme: buildTheme(Tokens.light, Brightness.light),
        home: Scaffold(body: Row(children: icons)),
      ));

  testWidgets('an agent\'s icon is its runtime\'s logo in the state colour; no dot, and the state is in the label',
      (tester) async {
    final semantics = tester.ensureSemantics();
    const k = Tokens.light;
    animateStatusSpinners = false;
    await pump(tester, const [
      StatusIcon.agent(Status.working, runtime: 'claude-code'),
      StatusIcon.agent(Status.needsYou, runtime: 'codex'),
      StatusIcon.agent(Status.idle, runtime: 'kimi'),
      StatusIcon.seat(Status.working, runtime: 'claude-code'),
    ]);
    final logos = tester.widgetList<ImageIcon>(find.byType(ImageIcon)).toList();
    expect(logos, hasLength(3), reason: 'claude, codex and the seat\'s claude');
    expect((logos[0].image as AssetImage).assetName, 'assets/icons/claude.png');
    expect(logos[0].color, k.added, reason: 'working is green');
    expect((logos[1].image as AssetImage).assetName, 'assets/icons/openai.png');
    expect(logos[1].color, k.accent, reason: 'needs you is orange');
    // A runtime with no logo gets the generic agent icon, tinted the same way (idle: grey).
    final generic = tester.widget<AppIcon>(find.byWidgetPredicate((w) => w is AppIcon && w.kind == AppIconKind.agent));
    expect(generic.color, k.muted);
    expect(find.byType(StatusShape), findsNothing, reason: 'no state dot on an agent');
    expect(find.bySemanticsLabel('Claude Code, working'), findsWidgets);
    expect(find.bySemanticsLabel('Codex, needs you'), findsOneWidget);
    expect(find.bySemanticsLabel('kimi, idle'), findsOneWidget, reason: 'a runtime with no logo is still named');
    semantics.dispose();
  });

  testWidgets('no runtime at all is the generic agent icon; subagents and shells keep their icons and dots', (tester) async {
    await pump(tester, const [
      StatusIcon.agent(Status.stopped),
      StatusIcon.subagent(Status.working),
      StatusIcon.shell(Status.working),
    ]);
    expect(find.byType(ImageIcon), findsNothing);
    expect(find.byWidgetPredicate((w) => w is AppIcon && w.kind == AppIconKind.agent), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is AppIcon && w.kind == AppIconKind.subagent), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is AppIcon && w.kind == AppIconKind.shell), findsOneWidget);
    expect(find.byType(StatusShape), findsOneWidget, reason: 'the subagent keeps its dot; a shell never had one');
  });
}
