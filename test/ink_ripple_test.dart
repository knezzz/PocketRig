// Every tappable tile or card on the main screens must ripple over exactly its
// own card: the InkWell's rect is the card's rect, the ink is clipped to the
// card's corner radius, and nothing opaque is painted between the InkWell and
// the Material it draws on (that hides the ripple).
//
// Screens come from test/golden/fixtures.dart, on a tall phone so lazy lists
// build every row. Failures print as file:line of the InkWell's construction
// site, with the reason; fix each at that site.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/ui/desktop_shell.dart' show AppShell;
import 'package:pocket_rig/data/fleet.dart';
import 'package:pocket_rig/data/rig_spec.dart';
import 'package:pocket_rig/ssh/ssh_exec.dart';
import 'package:pocket_rig/ui/chat_screen.dart';
import 'package:pocket_rig/ui/hosts_screen.dart';
import 'package:pocket_rig/ui/loose_agent_screen.dart';
import 'package:pocket_rig/ui/needs_you_banner.dart';
import 'package:pocket_rig/ui/project_screen.dart';
import 'package:pocket_rig/ui/registry_hosts_screen.dart';
import 'package:pocket_rig/ui/rig/work_queue_screen.dart';
import 'package:pocket_rig/ui/rig_screen.dart';
import 'package:pocket_rig/ui/spec_screen.dart';

import 'golden/fixtures.dart';

const walkHeight = 3200.0;
const _tall = walkHeight;
const _eps = 0.6;
const _maxGap = 8.0;

/// One screen to walk: its widget, and what to do before looking at it. Shared with the semantics test.
class ScreenWalk {
  const ScreenWalk(this.name, this.screen, {this.root = false, this.prepare, this.act});
  final String name;
  final Widget Function() screen;
  final bool root;
  final void Function()? prepare;
  final Future<void> Function(WidgetTester t)? act;
}

/// Lets polling, SSH and the fake streams land.
Future<void> settleScreen(WidgetTester t) async {
  for (var i = 0; i < 30; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Rect _rect(Element e) {
  final box = e.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

bool _same(Rect a, Rect b) =>
    (a.left - b.left).abs() < _eps &&
    (a.top - b.top).abs() < _eps &&
    (a.right - b.right).abs() < _eps &&
    (a.bottom - b.bottom).abs() < _eps;

/// null: not a rounded rectangle (circle, stadium...), so no radius to compare.
BorderRadius? _shapeRadius(ShapeBorder? s) => s is RoundedRectangleBorder ? s.borderRadius.resolve(TextDirection.ltr) : null;

bool _visible(Color? c) => c != null && c.a > 0;

/// A box that paints something the eye reads as a card edge.
bool _paintsCard(BoxDecoration d) => _visible(d.color) || d.gradient != null || d.border != null;

bool _paintsFill(BoxDecoration d) => _visible(d.color) || d.gradient != null;

/// Where a widget was constructed, as `lib/ui/kit.dart:278`, or null.
String? _creation(Widget w) {
  final json = w.toDiagnosticsNode().toJsonMap(InspectorSerializationDelegate(service: WidgetInspectorService.instance));
  final loc = json['creationLocation'];
  if (loc is! Map) return null;
  final file = '${loc['file']}';
  final i = file.indexOf('/lib/');
  return i < 0 || file.contains('/packages/flutter/') ? null : '${file.substring(i + 1)}:${loc['line']}';
}

/// The first app-owned construction site at or above [e], since a ListTile or
/// button builds its InkWell inside the framework.
String _site(Element e) {
  String? found = _creation(e.widget);
  if (found != null) return found;
  e.visitAncestorElements((a) {
    found = _creation(a.widget);
    return found == null;
  });
  return found ?? 'unknown (${e.debugGetCreatorChain(6)})';
}

String _r(Rect r) => '${r.width.toStringAsFixed(1)}x${r.height.toStringAsFixed(1)} at ${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)}';

String _br(BorderRadius? b) => b == null ? 'n/a' : (b == BorderRadius.zero ? 'square' : '${b.topLeft.x}/${b.topRight.x}/${b.bottomRight.x}/${b.bottomLeft.x}');

/// Reasons this InkResponse does not ripple over its card, empty when it does.
List<String> _check(InkResponse ink, Element e, double phoneWidth, List<Rect> targets) {
  final inkRect = _rect(e);
  Material? controller; // the Material the ripple is drawn on
  String? fillBetween;
  Widget? card;
  Rect? cardRect;
  BorderRadius? cardRadius;
  var cardClips = false;

  e.visitAncestorElements((a) {
    final w = a.widget;
    if (controller == null) {
      if (w is Material) {
        controller = w;
      } else if ((w is DecoratedBox && _paintsFill(w.decoration is BoxDecoration ? w.decoration as BoxDecoration : const BoxDecoration())) ||
          (w is ColoredBox && _visible(w.color))) {
        fillBetween ??= '${w.runtimeType} at ${_creation(w) ?? _site(a)}';
      }
    }
    if (card == null) {
      if (w is Material && (_visible(w.color) || w.shape != null || w.borderRadius != null)) {
        card = w;
        cardRect = _rect(a);
        cardRadius = w.borderRadius?.resolve(TextDirection.ltr) ?? _shapeRadius(w.shape) ?? (w.shape == null ? BorderRadius.zero : null);
        cardClips = w.clipBehavior != Clip.none;
      } else if (w is DecoratedBox && w.decoration is BoxDecoration && _paintsCard(w.decoration as BoxDecoration)) {
        final d = w.decoration as BoxDecoration;
        card = w;
        cardRect = _rect(a);
        cardRadius = d.shape == BoxShape.circle ? null : (d.borderRadius?.resolve(TextDirection.ltr) ?? BorderRadius.zero);
      }
    }
    return controller == null || card == null;
  });

  final problems = <String>[];
  if (fillBetween != null) problems.add('ripple hidden under a fill: $fillBetween sits between the InkWell and its Material');
  if (card == null || cardRect == null) return problems; // no card: a bare row on the page
  // The page or a sheet's own background is not a card.
  if (cardRadius == BorderRadius.zero && cardRect!.width >= phoneWidth - _eps) return problems;

  // What actually clips the ink: its own radius, else the Material it is drawn on, when that clips.
  final custom = ink.customBorder;
  BorderRadius? inkRadius = custom != null ? _shapeRadius(custom) : ink.borderRadius?.resolve(TextDirection.ltr);
  if (inkRadius == null && custom == null && controller != null && controller!.clipBehavior != Clip.none) {
    inkRadius = controller!.borderRadius?.resolve(TextDirection.ltr) ?? _shapeRadius(controller!.shape);
  }
  inkRadius ??= BorderRadius.zero;

  if (_same(inkRect, cardRect!)) {
    if (cardRadius != null && inkRadius != cardRadius) {
      problems.add('ink clipped to ${_br(inkRadius)} but the card is ${_br(cardRadius)}');
    }
    return problems;
  }
  // A row spanning a clipping card's full width is clipped by the card at its corners.
  final rowOfClippedCard = card is Material &&
      cardClips &&
      (inkRect.left - cardRect!.left).abs() < _eps &&
      (inkRect.right - cardRect!.right).abs() < _eps &&
      inkRect.top >= cardRect!.top - _eps &&
      inkRect.bottom <= cardRect!.bottom + _eps;
  if (!rowOfClippedCard && !_rowCoversCard(inkRect, cardRect!, targets)) {
    problems.add('ink rect ${_r(inkRect)} is not the card rect ${_r(cardRect!)}, and the row\'s tap targets leave a gap wider than $_maxGap px');
  }
  return problems;
}

/// A row may be several targets (a fold chevron and the body, a seat and its ⋯): together they must
/// span the card edge to edge, no gap wider than [_maxGap].
bool _rowCoversCard(Rect ink, Rect card, List<Rect> targets) {
  final row = targets.where((r) => r.center.dy >= ink.top && r.center.dy <= ink.bottom && r.left >= card.left - _eps && r.right <= card.right + _eps).toList()
    ..sort((a, b) => a.left.compareTo(b.left));
  var reach = card.left;
  for (final r in row) {
    if (r.left - reach > _maxGap + _eps) return false;
    if (r.right > reach) reach = r.right;
  }
  return card.right - reach <= _maxGap + _eps;
}

/// Walks every tappable InkResponse on screen and records failures by site.
int _walkScreen(WidgetTester t, String screen, Map<String, Set<String>> failures, Map<String, int> seen) {
  var count = 0;
  const phoneWidth = 390.0;
  bool isTappable(InkResponse ink) => ink.onTap != null || ink.onLongPress != null || ink.onDoubleTap != null;
  final all = find.byWidgetPredicate((w) => w is InkResponse && isTappable(w)).evaluate();
  // Every tap target counts toward covering a row, round icon buttons included.
  final targets = [for (final e in all) _rect(e)];
  for (final e in all) {
    final ink = e.widget as InkResponse;
    // Icon buttons, chips and switches are round or tiny targets, not cards.
    if (ink.highlightShape == BoxShape.circle) continue;
    count++;
    final site = _site(e);
    seen[site] = (seen[site] ?? 0) + 1;
    for (final p in _check(ink, e, phoneWidth, targets)) {
      failures.putIfAbsent(site, () => {}).add('[$screen] $p');
    }
  }
  return count;
}

/// Every main screen the tests walk, with what to do before looking at each.
List<ScreenWalk> screenWalks() => <ScreenWalk>[
    ScreenWalk('Inbox', () => const AppShell(), root: true),
    ScreenWalk('Menu', () => const AppShell(), root: true, act: openDrawer),
    ScreenWalk('Menu, rig open', () => const AppShell(),
        root: true, act: openDrawer, prepare: () => fleet.toggleRig('r:${homelab.id}|r-conveyor', allShown: false)),
    ScreenWalk('Menu, agents outside a rig', () => const AppShell(),
        root: true, act: openDrawer, prepare: () => showLoose = true),
    ScreenWalk('Settings', () => const HostsScreen(), root: true),
    ScreenWalk('ProjectScreen', () => const ProjectScreen(path: app)),
    ScreenWalk('RigScreen, list', () => RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', initialTab: 0)),
    ScreenWalk('RigScreen, overview', () => RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', tab: 1)),
    ScreenWalk('RigScreen, progress', () => RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', tab: 2)),
    ScreenWalk('RigScreen, map', () => RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', initialTab: 1)),
    ScreenWalk('Seat sheet', () => RigScreen(rig: rigFromFixture('r-conveyor'), projectName: 'app', initialTab: 1),
        act: (t) async {
      await t.longPress(find.text('lead').first);
      await settleScreen(t);
    }),
    ScreenWalk('Chat', () => ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true)),
    // A question the agent is waiting on, so the question card's rows are on screen.
    ScreenWalk('Chat, with a question', () => ChatScreen(rigName: 'conveyor', seat: seatFromFixture('r-conveyor', 'lead'), asChat: true),
        prepare: () => extraChatLog = [
              {
                'type': 'assistant',
                'uuid': 'q1',
                'message': {
                  'id': 'mq',
                  'content': [
                    {
                      'type': 'tool_use',
                      'id': 'tq',
                      'name': 'AskUserQuestion',
                      'input': {
                        'questions': [
                          {
                            'question': 'Which retry policy?',
                            'header': 'Retry',
                            'multiSelect': false,
                            'options': [
                              {'label': 'Fixed', 'description': 'same delay every time'},
                              {'label': 'Backoff', 'description': 'doubles each time'},
                            ],
                          }
                        ],
                      },
                    }
                  ],
                },
              },
            ]),
    ScreenWalk('Work queue', () => WorkScreen(rig: rigFromFixture('r-conveyor'))),
    ScreenWalk('Work handoffs', () => WorkScreen(rig: rigFromFixture('r-conveyor'), initialTab: 1)),
    ScreenWalk(
        'Rig spec',
        () => SpecScreen(
              file: RigSpecFile(path: '$app/rigs/release/rig.yaml', projectPath: app),
              text: releaseSpec,
              projectName: 'app',
            )),
    ScreenWalk('Agent outside a rig', () => LooseAgentScreen(agent: scratchAgent(), rigs: rigsWithSeatsFromFixture()),
        prepare: () => showLoose = true),
    ScreenWalk('Host editor', () => HostEditor(host: homelab)),
    // The registry list comes from the host's own `rig` command, so the fake shell answers it.
    ScreenWalk('Registry hosts', () => RegistryHostsScreen(host: homelab), prepare: () {
      SshExec.debugConnect = (_) async => SshExec.fake((cmd) async {
            if (cmd.contains('list')) {
              return '[{"id":"local","transport":"ssh","target":"localhost","selected":true},'
                  '{"id":"mini","transport":"ssh","target":"mini.ts.net","user":"me"},'
                  '{"id":"gpu","transport":"http","url":"http://gpu:7433"}]\npocketrig-host-ok\n';
            }
            if (cmd.contains('doctor') && cmd.contains('gpu')) return 'FAIL bearer token missing\npocketrig-host-ok\n';
            return 'ok reachable\npocketrig-host-ok\n';
          });
    }),
  ];

void main() {
  testWidgets('every tappable tile and card ripples over exactly its own card', (tester) async {
    tester.view.physicalSize = const ui.Size(390, _tall);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final walks = screenWalks();

    final failures = <String, Set<String>>{};
    final seen = <String, int>{};
    final empty = <String>[]; // screens that showed no tappable InkWell
    for (final w in walks) {
      needsYouAlerts.reset();
      final store = await installFakes();
      w.prepare?.call();
      // The goldens get Directionality and localizations from alchemist; here a bare app gives them.
      await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, home: phone(store, w.screen(), root: w.root, height: _tall)));
      await settleScreen(tester);
      await w.act?.call(tester);
      // Tabs (ProjectScreen): walk each one.
      final tabs = find.byType(Tab);
      final n = tabs.evaluate().length;
      if (n == 0) {
        empty.addAll(_walkScreen(tester, w.name, failures, seen) == 0 ? [w.name] : []);
      } else {
        for (var i = 0; i < n; i++) {
          await tester.tap(tabs.at(i));
          await settleScreen(tester);
          empty.addAll(_walkScreen(tester, '${w.name} > tab ${i + 1}', failures, seen) == 0 ? ['${w.name} > tab ${i + 1}'] : []);
        }
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }

    // A walk that finds nothing would pass for the wrong reason.
    expect(empty, isEmpty, reason: 'these screens showed nothing tappable, so they were not really walked');
    expect(seen.length, greaterThan(20), reason: 'walked only ${seen.length} InkWell sites: ${seen.keys}');
    final report = (failures.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
        .map((f) => '${f.key}  (x${seen[f.key]})\n    ${f.value.join('\n    ')}')
        .join('\n');
    expect(failures, isEmpty, reason: '${failures.length} of ${seen.length} InkWell sites do not ripple over their card:\n$report');
  });
}
