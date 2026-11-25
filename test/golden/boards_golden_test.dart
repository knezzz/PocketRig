// Golden tests for every board of the "RigPocket wireframes" canvas: the
// real screens, rendered on a 390×844 phone against the fake host in
// fixtures.dart, in light and dark.
//
//   flutter test test/golden                    # compare
//   flutter test test/golden --update-goldens   # regenerate
import 'dart:ui' show PointerDeviceKind;

import 'package:alchemist/alchemist.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/chat_cache.dart';
import 'package:pocket_rig/data/subagents.dart';
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/host_store.dart';
import 'package:pocket_rig/data/rig_spec.dart';
import 'package:pocket_rig/models.dart' show Host, Project, Seat;
import 'package:pocket_rig/terminal/transport.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/check_row.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat/question_card.dart' show AskQuestion, QuestionCard;
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell, panelShows;
import 'package:pocket_rig/ui/hosts/colour_picker.dart' show CustomColourPicker;
import 'package:pocket_rig/ui/hosts_screen.dart';
import 'package:pocket_rig/ui/inbox/question_carousel.dart';
import 'package:pocket_rig/ui/kit.dart' show BorderedList, KillBar, Panel, SectionLabel, Segmented;
import 'package:pocket_rig/ui/loose_agent_screen.dart';
import 'package:pocket_rig/ui/needs_you_banner.dart';
import 'package:pocket_rig/ui/agent_details.dart' show AgentDetails, SeatDetailsScreen;
import 'package:pocket_rig/ui/project_files.dart' show ProjectFilesScreen;
import 'package:pocket_rig/ui/recent_screen.dart' show RecentScreen;
import 'package:pocket_rig/ui/registry_hosts_screen.dart';
import 'package:pocket_rig/ui/project_screen.dart';
import 'package:pocket_rig/ui/rig/work_queue_screen.dart' show WorkScreen;
import 'package:pocket_rig/ui/rig/overview_tab.dart' show StartingCard;
import 'package:pocket_rig/ui/rig/seats_tab.dart' show SeatList;
import 'package:pocket_rig/ui/rig_screen.dart';
import 'package:pocket_rig/ui/rigs_home.dart';
import 'package:pocket_rig/ui/spec_editor_screen.dart';
import 'package:pocket_rig/ui/spec_screen.dart';
import 'package:pocket_rig/ui/status_shape.dart';
import 'package:pocket_rig/ui/terminal_screen.dart';

import 'fixtures.dart';

/// Let polling, SSH and the fake streams land (3 s in 100 ms steps), without
/// pumpAndSettle, which never settles while a spinner is visible.
/// conveyor's lead has a log in the cache, so its Inbox card shows what it did before it asked (the other seats have none).
/// A Mac window: the rig page's List | Tiles switch shows.
void _asDesktop() {
  isDesktop = true;
  addTearDown(() => isDesktop = false);
}

void _withInboxLog() {
  chatCache = _InboxLog();
  addTearDown(() => chatCache = null);
}

class _InboxLog extends ChatCache {
  _InboxLog() : super(NativeDatabase.memory());
  @override
  Future<List<String>> lastLines(String hostId, String key, int n) async => key != chatKey(seatFromFixture('r-conveyor', 'lead'))
      ? const []
      : [
          '{"type":"assistant","uuid":"a0","timestamp":"2026-11-09T10:00:00Z","message":{"id":"m0","role":"assistant","content":[{"type":"tool_use","id":"t0","name":"Bash","input":{"command":"flutter test"}}]}}',
          '{"type":"user","uuid":"u0","timestamp":"2026-11-09T10:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t0","content":"All 412 tests passed.\\n"}]}}',
          '{"type":"assistant","uuid":"a1","timestamp":"2026-11-09T10:00:02Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"I\'d like to run the integration suite."}]}}',
          '{"type":"assistant","uuid":"a2","timestamp":"2026-11-09T10:00:03Z","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"npm run test:integration"}}]}}',
        ];
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  // Asset images (the runtime glyphs) never decode in fake async otherwise.
  await precacheImages(tester);
}

/// Switches the project's tab in both the light and the dark scenario.
Future<void> _tabs(WidgetTester tester, String label) async {
  final tabs = find.descendant(of: find.byType(Segmented<int>), matching: find.text(label));
  for (var i = 0; i < tabs.evaluate().length; i++) {
    await tester.tap(tabs.at(i));
  }
}

/// Taps the first [tooltip] button in each scenario (light, then dark: the buttons come in two equal halves).
Future<void> _openMenu(WidgetTester tester, String tooltip) async {
  final n = find.byTooltip(tooltip).evaluate().length;
  for (final i in [0, n ~/ 2]) {
    await tester.tap(find.byTooltip(tooltip).at(i), warnIfMissed: false);
  }
}

/// Taps the menu button in each scenario (light, then dark).
Future<void> _openDrawer(WidgetTester tester) async {
  final n = find.byIcon(Icons.menu).evaluate().length;
  for (final i in [0, n ~/ 2]) {
    await tester.tap(find.byIcon(Icons.menu).at(i), warnIfMissed: false);
  }
}

late HostStore _store;

void _board(
  String fileName,
  String title,
  Widget Function() screen, {
  bool root = false,
  double height = 844,

  /// A window, not a phone: light and dark stack in one column instead of sitting side by side.
  double width = 390,
  Future<void> Function(WidgetTester tester)? after,

  /// Runs before the screen is built (a fake cache the screen reads).
  void Function()? before,
}) {
  goldenTest(
    title,
    fileName: fileName,
    pumpBeforeTest: (tester) async {
      before?.call();
      await _settle(tester);
      if (after != null) {
        await after(tester);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100)); // the fold animation needs frames, not one jump
        }
      }
    },
    builder: () => GoldenTestGroup(
      columns: width > 400 ? 1 : 2,
      children: [
        GoldenTestScenario(name: 'light', child: phone(_store, screen(), root: root, height: height, width: width)),
        GoldenTestScenario(name: 'dark', child: phone(_store, screen(), dark: true, root: root, height: height, width: width)),
      ],
    ),
  );
}

void main() {
  setUp(() async {
    needsYouAlerts.reset();
    panelShows.value = null;
    _store = await installFakes();
    pinAgoClock();
  });

  group('board', () {
    // The home screen is the Inbox; the sidebar tree is its drawer. Each board opens it.
    _board('1_projects', '1 · Menu (sidebar tree)', () => const AppShell(), root: true,
        after: (t) => _openDrawer(t));
    // conveyor unfolded: its seat rows, with the context % at the right edge (84% is red) and a running subagent
    // under lead as a compact row.
    _board('1_projects_rig_open', '1 · Menu (rig open)', () => const AppShell(),
        root: true, after: (t) async {
      fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: false);
      fleet.feedFor(homelab).subagents = {
        'sess-lead': [Subagent(sessionId: 'sess-lead', agentId: 'a1', description: 'Write the parser', type: 'general-purpose')],
      };
      await _openDrawer(t);
    });
    // A stopped agent in the sidebar (defender, the dashed ring) and an idle one, next to a working seat.
    _board('1_projects_rig_stopped', '1 · Menu (rig with a stopped agent)', () => const AppShell(), root: true, after: (t) async {
      fleet.toggleRig('r:${homelab.id}|r-adv', allShown: false);
      await _openDrawer(t);
    });
    _board('1a_project', '1a · Project · Overview', () => const ProjectScreen(path: app));
    _board('1a_project_agents', '1a · Project · Agents', () {
      showLoose = true;
      return const ProjectScreen(path: app);
    }, after: (tester) async {
      await _tabs(tester, 'Agents');
    });
    _board('1a_project_worktrees', '1a · Project · Worktrees', () {
      showLoose = true;
      return const ProjectScreen(path: app);
    }, after: (tester) async {
      await _tabs(tester, 'Worktrees');
    });
    _board('1a_project_specs', '1a · Project · Specs', () {
      showLoose = true;
      return const ProjectScreen(path: app);
    }, after: (tester) async {
      await _tabs(tester, 'Specs');
    });
    // A worktree's page: its branch, rigs and agents, with + Start rig on the Rigs label.
    _board('1a_worktree', '1a · Worktree', () {
      showWorktrees = true;
      return WorktreeScreen.load(host: homelab, project: Project(path: app), name: 'flaky-ci');
    });
    _board('1a_project_files', '1a · Project · Files', () => const ProjectFilesScreen(path: app, name: 'app'));
    // SSH can't connect: its own sentence and a Retry, not an empty folder.
    _board('1a_project_files_ssh', '1a · Project · Files (SSH down)', () {
      SshExec.debugConnect = (h) async => throw 'connection refused';
      return const ProjectFilesScreen(path: app, name: 'app');
    });
    // A 1280-wide window: headers and tab strips full width, the page body in its 880 column.
    // The Rigs home: every host, each project's rigs as cards of agent rows, then what runs outside a rig.
    _board('1c_rigs_home', '1c · Rigs home', () {
      showLoose = true;
      return const RigsHome();
    });
    // The same with the agents' cached chat logs: a working one's newest tool call, a waiting and an idle one's last reply.
    _board('1c_rigs_home_said', '1c · Rigs home, last said', () {
      showLoose = true;
      return const RigsHome();
    }, after: (t) async {
      final feed = fleet.feedFor(homelab);
      final conveyor = feed.rigs.firstWhere((r) => r.rig.name == 'conveyor');
      Seat seat(String id) => conveyor.seats.firstWhere((s) => s.logicalId == id);
      feed.lastMessages = {
        chatKey(seat('impl')): LastMessage(text: '', fromUser: false, tool: 'EDIT lib/ui/kit.dart'),
        chatKey(seat('lead')): LastMessage(text: 'I would like to push this to main.\nThe suite is green.', fromUser: false),
        chatKey(seat('tests')): LastMessage(text: 'flutter test passed · 412 ok', fromUser: false),
      };
      await t.pump(const Duration(seconds: 1));
    });
    // Rigs in worktrees: a chip on every rig card, on a row only where it differs; the agents outside a rig name their worktree.
    _board('1c_rigs_home_worktrees', '1c · Rigs home, worktrees', () {
      showLoose = true;
      showWorktrees = true;
      return const RigsHome();
    }, root: true, height: 1700);
    // The New sheet over the Rigs home: an agent, in a location, in one of its worktrees.
    _board('1d_new', '1d · New', () {
      SshExec.debugConnect = (_) async => SshExec.fake(fakeShell);
      addTearDown(() => SshExec.debugConnect = null);
      return const RigsHome();
    }, root: true, after: (t) async {
      // The board shows light and dark side by side: open the sheet in both.
      for (var i = 0; i < find.byTooltip('New…').evaluate().length; i++) {
        await t.tap(find.byTooltip('New…').at(i));
      }
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
    });
    _board('1d_new_worktrees', '1d · New, worktrees', () {
      SshExec.debugConnect = (_) async => SshExec.fake(fakeShell);
      addTearDown(() => SshExec.debugConnect = null);
      return const RigsHome();
    }, root: true, after: (t) async {
      for (var i = 0; i < find.byTooltip('New…').evaluate().length; i++) {
        await t.tap(find.byTooltip('New…').at(i));
      }
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      for (var i = 0; i < find.byTooltip('Worktree').evaluate().length; i++) {
        await t.tap(find.byTooltip('Worktree').at(i));
      }
      await t.pump(const Duration(seconds: 1));
    });
    // New worktree…: the branch name field with the keyboard up (the sheet scrolls so the field and Start stay in view), a name with
    // a space refused in place.
    _board('1d_new_branch', '1d · New, a new worktree', () {
      SshExec.debugConnect = (_) async => SshExec.fake(fakeShell);
      addTearDown(() => SshExec.debugConnect = null);
      return const RigsHome();
    }, root: true, after: (t) async {
      for (var i = 0; i < find.byTooltip('New…').evaluate().length; i++) {
        await t.tap(find.byTooltip('New…').at(i));
      }
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      // Each theme's own menu, one after the other (opening one closes when the item is chosen).
      for (var i = 0; i < 2; i++) {
        await t.tap(find.byTooltip('Worktree').at(i));
        await t.pump(const Duration(seconds: 1));
        await t.pump(const Duration(seconds: 1));
        await t.tap(find.text('New worktree…').last);
        await t.pump(const Duration(seconds: 1));
        await t.pump(const Duration(seconds: 1));
      }
      for (final f in find.byType(TextField).evaluate().toList()) {
        await t.enterText(find.byWidget(f.widget), 'fix this');
      }
      t.view.viewInsets = const FakeViewPadding(bottom: 336);
      addTearDown(t.view.resetViewInsets);
      await t.pump(const Duration(seconds: 1));
    });
    // The Mac: the same sheet as a 520dp dialog, and the Location menu with its hairline above Choose another folder….
    _board('1d_new_mac', '1d · New, Mac dialog', () {
      isDesktop = true;
      addTearDown(() => isDesktop = false);
      SshExec.debugConnect = (_) async => SshExec.fake(fakeShell);
      addTearDown(() => SshExec.debugConnect = null);
      return const RigsHome();
    }, root: true, width: 1280, height: 760, after: (t) async {
      for (var i = 0; i < find.byTooltip('New…').evaluate().length; i++) {
        await t.tap(find.byTooltip('New…').at(i));
      }
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
    });
    _board('1d_new_mac_dark', '1d · New, Mac dialog, from the dark page', () {
      isDesktop = true;
      addTearDown(() => isDesktop = false);
      SshExec.debugConnect = (_) async => SshExec.fake(fakeShell);
      addTearDown(() => SshExec.debugConnect = null);
      return const RigsHome();
    }, root: true, width: 1280, height: 760, after: (t) async {
      for (var i = 0; i < find.byTooltip('New…').evaluate().length; i++) {
        // The dialog is one for the window: opened from the dark page, it takes the dark theme.
        if (i == 1) await t.tap(find.byTooltip('New…').at(i));
      }
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
    });
    // The New sheet's Location typed by hand: asked on the host (spinner, ✓, no such folder, an unreachable host, not a git
    // repository: no Worktree field). Light and dark side by side, each pane's own sheet.
    void typedBoard(String id, String title, String text, {Duration wait = const Duration(milliseconds: 900), bool unreachable = false, bool keyboard = false}) {
      _board(id, title, () {
        SshExec.debugConnect = (_) async => SshExec.fake(fakeShell);
        addTearDown(() => SshExec.debugConnect = null);
        return const RigsHome();
      }, root: true, after: (t) async {
        for (var i = 0; i < find.byTooltip('New…').evaluate().length; i++) {
          await t.tap(find.byTooltip('New…').at(i));
        }
        await t.pump(const Duration(seconds: 1));
        await t.pump(const Duration(seconds: 1));
        for (var i = 0; i < 2; i++) {
          await t.tap(find.byTooltip('Location').at(i));
          await t.pump(const Duration(seconds: 1));
          await t.pump(const Duration(seconds: 1));
          await t.tap(find.text('Type a path…').last);
          await t.pump(const Duration(seconds: 1));
        }
        if (unreachable) SshExec.debugConnect = (_) async => throw 'connection refused';
        for (final f in find.byType(TextField).evaluate().toList()) {
          await t.enterText(find.byWidget(f.widget), text);
        }
        if (keyboard) t.view.viewInsets = const FakeViewPadding(bottom: 336);
        if (keyboard) addTearDown(t.view.resetViewInsets);
        await t.pump(wait);
        await t.pump(const Duration(milliseconds: 300));
      });
    }

    typedBoard('1d_new_path_checking', '1d · New, typed path, checking', '~/code/app', wait: const Duration(milliseconds: 100));
    typedBoard('1d_new_path_ok', '1d · New, typed path, a folder', '~/code/app');
    typedBoard('1d_new_path_missing', '1d · New, typed path, no such folder', '~/code/missing');
    typedBoard('1d_new_path_transport', '1d · New, typed path, host unreachable', '~/code/foo', unreachable: true);
    typedBoard('1d_new_path_nogit', '1d · New, typed path, not a git repository', '/srv/x');
    typedBoard('1d_new_path_keyboard', '1d · New, typed path, keyboard up', '~/code/missing', keyboard: true);
    _board('1d_new_mac_location', '1d · New, Mac, the Location menu', () {
      isDesktop = true;
      addTearDown(() => isDesktop = false);
      SshExec.debugConnect = (_) async => SshExec.fake(fakeShell);
      addTearDown(() => SshExec.debugConnect = null);
      return const RigsHome();
    }, root: true, width: 1280, height: 760, after: (t) async {
      await t.tap(find.byTooltip('New…').first);
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.byTooltip('Location').first);
      await t.pump(const Duration(seconds: 1));
    });
    _board('1c_rigs_home_wide', '1c · Rigs home, 1280 wide', () {
      showLoose = true;
      return const RigsHome();
    }, root: true, width: 1280, height: 900);
    _board('15_settings_wide', '15 · Settings, 1280 wide', () => const HostsScreen(), root: true, width: 1280, height: 720);
    _board('15_project_wide', '15 · Project, 1280 wide', () => const ProjectScreen(path: app), root: true, width: 1280, height: 720);
    _board(
      '1b_spec',
      '1b · Rig spec',
      () => SpecScreen(
        file: RigSpecFile(path: '$app/rigs/release/rig.yaml', projectPath: app),
        text: releaseSpec,
        projectName: 'app',
      ),
    );
    _board(
      '1b_spec_graph',
      '1b · Rig spec › Graph',
      () => SpecScreen(
        file: RigSpecFile(path: '$app/rigs/release/rig.yaml', projectPath: app),
        text: releaseSpec,
        projectName: 'app',
        initialView: 1,
      ),
    );
    _board(
      '1c_spec_editor',
      '1c · Rig spec editor',
      () => SpecEditorScreen(
        file: RigSpecFile(path: '$app/rigs/release/rig.yaml', projectPath: app),
        text: releaseSpec,
        projectName: 'app',
      ),
    );
    _board('2a_rig_overview', '2a · Rig › Overview',
        () => RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', tab: 1));
    // The same overview scrolled to the end: the Rig tools action rows.
    _board('2a_rig_overview_bottom', '2a · Rig › Overview (bottom)',
        () => RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', tab: 1),
        after: (tester) async {
      for (final list in tester.stateList<ScrollableState>(find.byType(Scrollable))) {
        if (list.position.axis == Axis.vertical) list.position.jumpTo(list.position.maxScrollExtent);
      }
    });
    _board('2c_rig_seats', '2c · Rig › Seats',
        () => RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', initialTab: 1));
    // A 1280-wide window: the rig's actions are buttons in the header bar, not tiles.
    _board('2c_rig_wide', '2c · Rig, 1280 wide',
        () => RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', initialTab: 0), root: true, width: 1280, height: 900, before: _asDesktop);
    _board('2c_rig_graph_wide', '2c · Rig › Graph, 1280 wide',
        () => RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', initialTab: 1), root: true, width: 1280, height: 720, before: _asDesktop);
    // A rig still starting: the dashed STARTING… card, then its agents, one up and the rest dimmed "not ready".
    _board('2c_rig_starting', '2c · Rig starting', () {
      Seat seat(String id, String? startup) => Seat.fromJson({
            ...nodes['r-conveyor']!.firstWhere((n) => n['logicalId'] == 'impl'),
            'logicalId': id,
            'startupStatus': startup,
          });
      final seats = [seat('lead', 'ready'), seat('impl', 'pending'), seat('review', 'pending')];
      return Scaffold(
          body: SafeArea(
              child: ListView(padding: const EdgeInsets.all(20), children: [
        StartingCard(agents: seats),
        const SizedBox(height: 16),
        SeatList(seats: seats, onOpen: (_) {}, onMore: (_) {}),
      ])));
    });
    // The rig page's Stop, filled and outlined (red text and hairline), one over the other.
    _board('2c_stop_bar_variants', '2c · Stop bar, filled and outlined',
        () => Scaffold(
              body: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                KillBar([('Stop rig…', Icons.stop_circle_outlined, () {})]),
                const SizedBox(height: 24),
                KillBar([('Stop rig…', Icons.stop_circle_outlined, () {})], outlined: true),
              ]),
            ),
        height: 360);
    _board('2c_rig_stopped', '2c · Rig › Seats (stopped: green Restore, red Delete)',
        () => RigScreen(rig: rigFromFixture('r-research'), projectName: 'loyalty', initialTab: 1));
    _board('2c_rig_seats_list', '2c · Rig › Seats (List)',
        () => RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', initialTab: 0));
    _board('2e_rig_progress', '2e · Rig › Progress',
        () => RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', tab: 2));
    _board('2e_rig_messages', '2e · Rig › Progress (Messages)',
        () => RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', tab: 2), after: (tester) async {
      for (final list in tester.stateList<ScrollableState>(find.byType(Scrollable))) {
        if (list.position.axis == Axis.vertical) list.position.jumpTo(list.position.maxScrollExtent);
      }
    });
    _board('2c_rig_seats_release', '2c · Rig › Seats (3 pods, escalation)',
        () => RigScreen(rig: releaseRig, projectName: 'app', initialTab: 1));
    _board('2d_rig_work', '2d · Rig › Work', () => WorkScreen(rig: rigFromFixture('r-conveyor')));
    _board('3a_seat_chat', '3a · Seat chat',
        () => ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true));
    // The ⋯ menu as one action sheet: a loose agent's chat menu (terminal, details, red Kill agent) ...
    _board('3e_chat_menu_loose', '3 · Chat menu · agent outside a rig', () {
      showLoose = true;
      return ChatScreen(rigName: 'no rig', seat: scratchAgent().toSeat(), loose: scratchAgent(), rigs: rigsWithSeatsFromFixture(), asChat: true);
    }, after: (tester) => _openMenu(tester, 'Menu'));
    // ... and ProjectScreen's rig menu (rows with subtitles, red Stop… / Delete…).
    _board('1b_rig_menu', '1a · Project · rig menu', () => const ProjectScreen(path: app), after: (tester) async {
      await _tabs(tester, 'Agents');
      await tester.pump(const Duration(milliseconds: 300));
      await _openMenu(tester, 'Rig actions');
    });
    _board('3b_seat_terminal', '3b · Seat terminal',
        () => TerminalScreen(target: SeatTarget('conveyor', seatFromFixture('r-conveyor', 'lead'))));
    // The seat sheet's page: its sections are hairline cards of rows.
    _board('3c_seat_details', '3c · Seat details',
        () => SeatDetailsScreen(
            details: AgentDetails(seat: seatFromFixture('r-conveyor', 'lead'), jobs: const []),
            rigName: 'conveyor',
            onJobs: () {}));
    // The chat's question card: options edge to edge in the accent card, with Other.
    _board(
        '3d_question_card',
        '3d · Chat · questions',
        () => Scaffold(
              body: Padding(
                padding: const EdgeInsets.fromLTRB(16, 60, 16, 16),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: QuestionCard(
                    seatName: 'review',
                    onSend: (_, __) {},
                    onDecline: () {},
                    questions: const [
                      AskQuestion('Which branch should the fix land on?', 'Branch', false, [
                        ('main', 'Ships with the next release'),
                        ('release/2.4', 'Backport only'),
                      ]),
                      AskQuestion(
                          'What should it run?', 'Checks', true, [('Unit tests', null), ('Integration suite', null)]),
                    ],
                  ),
                ),
              ),
            ));
    _board('4_inbox', '4 · Inbox', () => const AppShell(), root: true, before: _withInboxLog);
    // On a wide window the items are a one-line list on the left and the selected one is open on the right.
    _board('4_inbox_wide', '4 · Inbox, 1280 wide', () => const RecentScreen(visible: false), root: true, width: 1280, height: 720,
        before: _withInboxLog);
    // The Inbox below the Needs you cards: the agents at work.
    _board('4b_inbox_working', '4 · Inbox · working', () => const AppShell(), root: true,
        after: (tester) async {
      final lists = find.byType(Scrollable);
      for (var i = 0; i < lists.evaluate().length; i++) {
        await tester.drag(lists.at(i), const Offset(0, -120));
      }
    });
    // One seat's questions, as the Inbox card shows them: radio rows, then the Other field.
    _board(
        '4c_question_carousel',
        '4 · Inbox · questions',
        () => Scaffold(
              body: Padding(
                padding: const EdgeInsets.fromLTRB(16, 60, 16, 16),
                child: QuestionCarousel(
                  seatName: 'review',
                  onSend: (_, __) {},
                  onDecline: () {},
                  questions: const [
                    AskQuestion('Which branch should the fix land on?', 'Branch', false, [
                      ('main', 'Ships with the next release'),
                      ('release/2.4', 'Backport only'),
                      ('A new branch', null),
                    ]),
                    AskQuestion('What should it run?', 'Checks', true, [
                      ('Unit tests', null),
                      ('Integration suite', 'About four minutes'),
                    ]),
                  ],
                ),
              ),
            ));
    _board('7_projects_loose', '7 · Menu · agents outside a rig', () {
      showLoose = true;
      return const AppShell();
    }, root: true, after: _openDrawer);
    // The sidebar's bars: rigs of one, two and six seats, a long name, and a rig with every seat idle (one row).
    _board('1b_menu_bars', '1b · Menu · bars', () {
      showBarRigs = true;
      return const AppShell();
    }, root: true, after: _openDrawer);
    // The same, tall enough for every rig; then with a seat on show (its rig and project marked), a rig on show, and
    // with a mouse (20dp bars, 36dp rows).
    Widget bars() {
      showBarRigs = true;
      return const AppShell();
    }
    // The six-seat rig with every seat listed (it shows only its working ones until unfolded).
    void unfoldSix() => fleet.toggleRig('r:${homelab.id}|r-six-seat-pipeline', allShown: false);
    _board('1b_menu_bars_tall', '1b · Menu · bars, tall', bars, root: true, height: 1500, after: (t) async {
      unfoldSix();
      await _openDrawer(t);
    });
    _board('1b_menu_bars_seat', '1b · Menu · bars, a seat on show', bars, root: true, height: 1500, after: (t) async {
      unfoldSix();
      panelShows.value = 'seat:r-six-seat-pipeline/planner';
      await _openDrawer(t);
    });
    _board('1b_menu_bars_rig', '1b · Menu · bars, a rig on show', bars, root: true, height: 1500, after: (t) async {
      unfoldSix();
      panelShows.value = 'rig:r-duo';
      await _openDrawer(t);
    });
    _board('1b_menu_bars_mouse', '1b · Menu · bars, mouse', bars, root: true, height: 1200, after: (t) async {
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      addTearDown(mouse.removePointer);
      unfoldSix();
      fleet.feedFor(homelab).subagents = {
        'sess-planner': [Subagent(sessionId: 'sess-planner', agentId: 'a1', description: 'Write the parser', type: 'general-purpose')],
      };
      await _openDrawer(t);
    });
    // A worktree's agents outside a rig: scratch waits on a permission, so its row carries the accent pill.
    _board('7d_worktree_loose', '7 · Worktree · agents outside a rig', () {
      showLoose = true;
      return WorktreeScreen.load(host: homelab, project: Project(path: app), name: null);
    });
    _board('7a_loose_agent', '7a · Agent outside a rig', () {
      showLoose = true;
      return LooseAgentScreen(agent: scratchAgent(), rigs: rigsWithSeatsFromFixture());
    });
    _board('6b_in_app_banner', '6b · In-app banner', () {
      // The banner for lead, over the Projects tab, as PocketRigApp shows it.
      needsYouAlerts.show(SeatAlert(
        host: homelab,
        rig: rigFromFixture('r-conveyor'),
        seat: seatFromFixture('r-conveyor', 'lead'),
        project: 'app',
      ));
      return const Stack(children: [
        AppShell(),
        Positioned(left: 10, right: 10, top: 53, child: NeedsYouBanner()),
      ]);
    }, root: true);
    _board('5_settings', '5 · Settings', () => const HostsScreen(), root: true);
    _board('5_host_editor', '5 · Host editor', () => HostEditor(host: homelab));
    // A host with its own colour: the last swatch holds it, selected.
    _board('5_host_editor_custom', '5 · Host editor · custom colour', () => HostEditor(host: Host.fromJson({...homelab.toJson(), 'color': 0xFF1E88E5})));
    // The picker (a bottom sheet on a phone): a colour that reads, and one too close to the ground (pulled, with its note).
    _board('5c_colour_picker', '5 · Custom colour', () => const Scaffold(body: Align(alignment: Alignment.bottomCenter, child: CustomColourPicker(initial: Color(0xFF1E88E5), hostName: 'homelab'))));
    _board('5c_colour_picker_pulled', '5 · Custom colour · lightened/darkened', () => const Scaffold(body: Align(alignment: Alignment.bottomCenter, child: CustomColourPicker(initial: Color(0xFF7A7F9A), hostName: 'homelab'))));
    // The daemon's own hosts: the doctor results come from its fake `rig` command.
    _board('5b_registry_hosts', '5 · OpenRig hosts', () {
      SshExec.debugConnect = (_) async => SshExec.fake((cmd) async {
            if (cmd.contains('list')) {
              return '[{"id":"local","transport":"ssh","target":"localhost","selected":true},'
                  '{"id":"mini","transport":"ssh","target":"mini.ts.net","user":"me"},'
                  '{"id":"gpu","transport":"http","url":"http://gpu:7433"}]\npocketrig-host-ok\n';
            }
            if (cmd.contains('doctor') && cmd.contains('gpu')) return 'FAIL bearer token missing\npocketrig-host-ok\n';
            return 'ok reachable\npocketrig-host-ok\n';
          });
      addTearDown(() => SshExec.debugConnect = null);
      return RegistryHostsScreen(host: homelab);
    });
    // Every status mark, as the rows draw it: the circle, the tally's small one, and the rig and agent badges.
    _board('8_status_marks', '8 · Status marks', () => const _StatusMarks());
    // The one check row in its three layouts, every state: Health tiles, launch checks, checklists.
    _board('8b_check_rows', '8 · Check rows', () => const _CheckRows());
  });
}

class _CheckRows extends StatelessWidget {
  const _CheckRows();
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const SectionLabel('Health'),
            BorderedList(children: [
              const CheckRow(CheckState.ok, 'Daemon', detail: 'direct · :7433', layout: CheckLayout.tile),
              const CheckRow(CheckState.bad, 'SSH', detail: 'refused: the host key changed', layout: CheckLayout.tile),
              const CheckRow(CheckState.off, 'Host key', detail: '—', layout: CheckLayout.tile),
              CheckRow(CheckState.ok, 'Watcher & hooks', detail: 'running · hooks in place', layout: CheckLayout.tile, onTap: () {}),
            ]),
            const SizedBox(height: 18),
            const SectionLabel('Launch checks'),
            const Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                CheckRow(CheckState.ok, 'Spec is valid', layout: CheckLayout.stacked),
                CheckRow(CheckState.bad, 'Runtimes found', detail: 'failed · codex is not installed', layout: CheckLayout.stacked),
                CheckRow(CheckState.off, 'Installs', detail: 'skipped', layout: CheckLayout.stacked),
              ]),
            ),
            const SizedBox(height: 18),
            const SectionLabel('Checklist'),
            const Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                CheckRow(CheckState.ok, 'Design the backoff', struck: true),
                CheckRow(CheckState.todo, 'Implement it in the router'),
                CheckRow(CheckState.ok, 'Unit tests', indent: 16, struck: true),
                CheckRow(CheckState.bad, 'Staging run', indent: 16),
              ]),
            ),
          ]),
        ),
      );
}

class _StatusMarks extends StatelessWidget {
  const _StatusMarks();
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final s in Status.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(children: [
                      SizedBox(width: 24, child: Center(child: StatusShape(s, size: 12))),
                      const SizedBox(width: 12),
                      StatusCount(s, 2),
                      const SizedBox(width: 20),
                      StatusIcon.rig(s),
                      const SizedBox(width: 16),
                      StatusIcon.agent(s),
                      const SizedBox(width: 16),
                      Expanded(child: Text(s.label, style: const TextStyle(fontSize: 14))),
                    ]),
                  ),
              ]),
            ),
          ),
        ),
      );
}
