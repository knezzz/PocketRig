import 'package:flutter/foundation.dart';

import '../models.dart';

/// One thing waiting on the person: an agent seat needing input, a waiting loose agent, or a daemon action item
/// addressed to them. The Inbox's Needs you section lists exactly these, and every count is made from them.
class NeedsYouItem {
  NeedsYouItem.seat(RigWithSeats this.rig, Seat this.seat)
      : loose = null,
        action = null;
  NeedsYouItem.loose(LooseAgent this.loose)
      : rig = null,
        seat = null,
        action = null;

  /// [rig]: the feed's rig named by the asker ("lead@conveyor"), when there is one.
  NeedsYouItem.action(AttentionItem this.action, this.rig)
      : seat = null,
        loose = null;

  /// The rig it belongs to: its seat's, or the one an action item's asker names.
  final RigWithSeats? rig;
  final Seat? seat;
  final LooseAgent? loose;
  final AttentionItem? action;

  bool inRig(RigWithSeats r) => rig?.rig.id == r.rig.id;

  /// Counts toward [p]: its rigs' items and its loose agents, and an action item that names no rig of the feed
  /// by the folder it names.
  bool inProject(Project p) {
    if (rig != null) return p.rigs.any(inRig);
    if (loose != null) return p.loose.any((a) => a.id == loose!.id);
    final root = action!.projectRoot;
    return root != null && (isUnder(root, p.path) || p.path == mainCheckout(root));
  }
}

/// The one needs-you list. Its length is the tab badge; cards, tallies and rig rows count the items in them.
List<NeedsYouItem> needsYouList(
    Iterable<RigWithSeats> rigs, Iterable<LooseAgent> loose, Iterable<AttentionItem> attention) {
  RigWithSeats? named(AttentionItem i) {
    final asker = i.asker;
    if (asker == null || !asker.contains('@')) return null;
    final name = asker.split('@').last;
    return rigs.where((r) => r.rig.name == name).firstOrNull;
  }

  return [
    for (final r in rigs)
      for (final s in r.seats)
        if (s.isAgent && s.state == SeatState.needsYou) NeedsYouItem.seat(r, s),
    for (final a in loose)
      if (a.waiting) NeedsYouItem.loose(a),
    for (final i in attention)
      if (i.kind == 'action') NeedsYouItem.action(i, named(i)),
  ];
}

/// The seat an action item points at, as (rig name, seat): the rig's own seat when [rigs] has it, so a Claude seat
/// opens in its chat; else a seat named by the asker's session (a rig that's gone still opens its terminal). Null
/// when the item names no asker: there is nobody to open.
(String, Seat)? attentionTarget(List<RigWithSeats> rigs, AttentionItem i) {
  final asker = i.asker;
  if (asker == null) return null;
  final found = [
    for (final r in rigs)
      for (final s in r.seats)
        if (s.sessionName == asker) (r.rig.name, s)
  ].firstOrNull;
  return found ?? (asker.contains('@') ? asker.split('@').last : '', Seat(rigId: '', logicalId: asker.split('@').first, sessionName: asker));
}

/// What a seat is asking, from the daemon's needs-input reason. OpenRig
/// sends codes (`permission_prompt`, `selection_prompt`, `idle_prompt`);
/// older daemons and the hook sent `Bash: npm test` or free text.
class PermissionAsk {
  PermissionAsk({this.tool, required this.detail, bool? permission}) : isPermission = permission ?? tool != null;
  final String? tool;
  final String detail;

  /// A tool call waiting for Allow / Always / Deny, rather than a question.
  final bool isPermission;

  static final _toolLine = RegExp(r'^([A-Z][A-Za-z]+)(?:\(|:\s*)(.*?)\)?$', dotAll: true);

  factory PermissionAsk.from(Seat seat) {
    final r = seat.needsInputReason?.trim();
    if (r == null || r.isEmpty) return PermissionAsk(detail: 'Waiting for permission — see the terminal');
    switch (r) {
      // The daemon knows a permission menu is up, not which tool asked.
      case 'permission_prompt':
        return PermissionAsk(detail: 'Wants to use a tool. The command is in its terminal.', permission: true);
      case 'selection_prompt':
        return PermissionAsk(detail: 'Asked you to pick an option');
      case 'idle_prompt':
        return PermissionAsk(detail: 'Waiting for your input');
    }
    final m = _toolLine.firstMatch(r);
    if (m != null && m.group(2)!.trim().isNotEmpty) return PermissionAsk(tool: m.group(1), detail: m.group(2)!.trim());
    return PermissionAsk(detail: r);
  }

  String question(String seat) => switch (tool) {
        'Bash' => 'Allow $seat to run this command?',
        'Edit' || 'Write' || 'MultiEdit' || 'NotebookEdit' => 'Allow $seat to edit this file?',
        'WebFetch' => 'Allow $seat to fetch this page?',
        null => 'Allow $seat to continue?',
        final t => 'Allow $seat to use $t?',
      };

  /// What "Always allow" covers for a command: its first two words
  /// (`npm run`), which is how Claude Code scopes Bash rules.
  String? get alwaysScope {
    if (tool != 'Bash') return null;
    final words = detail.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return null;
    return words.take(words.length > 1 ? 2 : 1).join(' ');
  }
}

/// One seat that needs you, with everything the banner names:
/// role › rig › project › device.
class SeatAlert {
  SeatAlert({required this.host, required this.rig, required this.seat, this.project});
  final Host host;
  final Rig rig;
  final Seat seat;
  final String? project;

  String get key => '${host.id}|${seat.sessionName ?? '${rig.id}/${seat.logicalId}'}';
  String get path => [seat.logicalId, rig.name, project, host.name].whereType<String>().join(' › ');
  PermissionAsk get ask => PermissionAsk.from(seat);
  bool get isPermission => ask.isPermission;
  String get kind => isPermission ? NotifyKind.permission.id : NotifyKind.question.id;
  String get title => isPermission ? '${seat.logicalId} needs approval' : '${seat.logicalId} asked a question';
}

/// Which seats just started waiting, for the banner. Every host's feed
/// reports each refresh; the first report per host only seeds, so opening
/// the app doesn't replay old asks.
class NeedsYouAlerts extends ChangeNotifier {
  /// Alert keys seen waiting in each host's last report.
  final Map<String, Set<String>> _known = {};
  final List<SeatAlert> _queue = [];

  String? _focused;

  /// The seat on screen right now (chat or terminal): no banner for it.
  /// Opening a seat also takes down the banner it already has, since the
  /// screen shows the same ask with the same buttons.
  String? get focusedSession => _focused;
  set focusedSession(String? session) {
    _focused = session;
    if (session == null) return;
    final n = _queue.length;
    _queue.removeWhere((a) => a.seat.sessionName == session);
    if (_queue.length != n) notifyListeners();
  }

  SeatAlert? get current => _queue.firstOrNull;

  /// Seats swiped away for a while, by alert key: until when.
  final Map<String, DateTime> _snoozed = {};

  /// How long a swipe up keeps a seat's banner away.
  static const snoozeFor = Duration(minutes: 10);

  /// Banners waiting behind the one shown.
  int get queued => _queue.length;

  void report(Host host, List<SeatAlert> waiting, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final keys = {for (final a in waiting) a.key};
    final known = _known[host.id];
    final before = _queue.length;
    _queue.removeWhere((a) => a.host.id == host.id && !keys.contains(a.key));
    _snoozed.removeWhere((key, _) => key.startsWith('${host.id}|') && !keys.contains(key));
    var changed = _queue.length != before;
    for (final a in waiting) {
      final until = _snoozed[a.key];
      if (until != null) {
        if (t.isBefore(until)) continue;
        // The snooze is over and it's still waiting: up it comes again.
        _snoozed.remove(a.key);
      } else if (known == null || known.contains(a.key)) {
        continue;
      }
      if (!host.notifyKinds.contains(a.kind)) continue;
      if (a.seat.sessionName != null && a.seat.sessionName == _focused) continue;
      if (_queue.any((x) => x.key == a.key)) continue;
      _queue.add(a);
      changed = true;
    }
    _known[host.id] = keys;
    if (changed) notifyListeners();
  }

  /// Swiped up: [a]'s banner stays away for [snoozeFor] (or [d]), then comes
  /// back if the seat is still waiting.
  void snooze(SeatAlert a, {Duration d = snoozeFor, DateTime? now}) {
    _snoozed[a.key] = (now ?? DateTime.now()).add(d);
    dismiss(a);
  }

  /// [hostId] was removed: its banners go with it.
  void forgetHost(String hostId) {
    _known.remove(hostId);
    final n = _queue.length;
    _queue.removeWhere((a) => a.host.id == hostId);
    if (_queue.length != n) notifyListeners();
  }

  void dismiss(SeatAlert a) {
    _queue.removeWhere((x) => x.key == a.key);
    notifyListeners();
  }

  /// [seat] was answered somewhere (chat, terminal, Needs you tab): its
  /// banner goes straight away instead of waiting for the next refresh to
  /// notice the seat stopped waiting.
  void answered(Seat seat) {
    // Still waiting after a moment: the next ask (see [answerSettle]) gets its banner.
    final alert = _queue.where((a) => a.seat.sessionName != null && a.seat.sessionName == seat.sessionName).firstOrNull;
    if (alert != null) _snoozed[alert.key] = DateTime.now().add(answerSettle);
    final n = _queue.length;
    _queue.removeWhere((a) => a.seat.sessionName != null && seat.sessionName != null
        ? a.seat.sessionName == seat.sessionName
        : a.seat.rigId == seat.rigId && a.seat.logicalId == seat.logicalId);
    if (_queue.length != n) notifyListeners();
  }

  /// Puts [a] up straight away (tests and goldens).
  @visibleForTesting
  void show(SeatAlert a) {
    _queue.insert(0, a);
    notifyListeners();
  }

  @visibleForTesting
  void reset() {
    _known.clear();
    _queue.clear();
    _snoozed.clear();
    _focused = null;
    notifyListeners();
  }
}

final needsYouAlerts = NeedsYouAlerts();

/// How long an answered ask stays hidden while the daemon still reports it: it lags the keypress. After
/// that a seat that still waits is asking something new (an agent's parallel tool calls ask one by one).
const answerSettle = Duration(seconds: 4);

/// What identifies the ask a seat is showing; it changes when the next one comes.
String askSig(Seat s) => '${s.needsInputReason}|${s.waitingSince}';

/// Whether a seat that still waits, [since] it was answered while it showed [sig], has a new ask.
bool askMoved(Seat now, String sig, DateTime since) =>
    now.needsInput && (askSig(now) != sig || DateTime.now().difference(since) >= answerSettle);

/// Agents waiting on you across every host, for the tab label.
final needsYouCount = ValueNotifier<int>(0);
