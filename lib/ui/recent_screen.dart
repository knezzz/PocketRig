import 'dart:async';

import 'package:flutter/material.dart';

import 'empty_note.dart';
import 'page_column.dart';
import '../data/chat_cache.dart';
import '../data/core_answer.dart';
import '../data/core_app.dart';
import '../data/core_ask.dart';
import '../data/fleet.dart';
import '../data/needs_you.dart' show askMoved, askSig, attentionTarget;
import '../data/usage_rings.dart';
import '../main.dart';
import '../models.dart';
import '../terminal/transport.dart';
import 'chat_screen.dart';
import 'common.dart';
import 'desktop_shell.dart';
import 'inbox/answering.dart';
import 'inbox/core_ask_card.dart';
import 'inbox/needs_you_card.dart';
import 'kit.dart';
import 'loose_agent_screen.dart';
import 'needs_you_banner.dart' show inboxRequests;
import 'rig/rig_chat.dart';
import 'status_shape.dart';
import 'theme.dart';
import 'terminal_screen.dart';

/// The Inbox: what's waiting on you on every host, answerable right on its card, then the newest handoffs seats
/// sent each other. Working agents are in the sidebar.
class RecentScreen extends StatefulWidget {
  const RecentScreen({super.key, this.visible = true, this.column = false});

  /// The Inbox as a column beside the Rigs home: a small 'INBOX · N  Open ›' label instead of the page header.
  final bool column;

  /// On screen: only then are the agents' logs read over SSH.
  final bool visible;

  @override
  State<RecentScreen> createState() => _RecentScreenState();
}

class _RecentScreenState extends State<RecentScreen> {
  List<HostFeed> _feeds = const [];
  Listenable _merged = toastProblems;
  Timer? _messages;

  /// The newest queue items on each host, by host id.
  final Map<String, List<QueueItem>> _handoffs = {};

  /// Each host's structured questions (the Core app job) and its state, by host id.
  final Map<String, (CoreApp, List<CoreAsk>)> _core = {};

  /// Questions answered here: kept on screen as 'Answered' after the host stops listing them, by `hostId|requestId`.
  final Map<String, CoreAsk> _tracked = {};

  /// The order questions first appeared in: a question keeps its place after it is answered and leaves the host's list.
  final List<String> _askOrder = [];

  /// Each waiting agent's ask from its log, and what it was loaded for.
  final Map<String, PendingAsk?> _pending = {};
  final Map<String, String> _pendingFor = {};

  /// The open item: on a phone it is open in place (null: the first; '': none), on a wide window it is the one shown beside
  /// the list.
  String? _open;

  /// Answered from here: hidden until the feed catches up.
  final Map<String, (DateTime, String)> _answered = {};

  @override
  void initState() {
    super.initState();
    _messages = Timer.periodic(const Duration(seconds: 30), (_) => _loadMessages());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMessages();
      if (mounted && usageNow.stale) usageNow.fetch(AppScope.read(context).hosts).catchError((_) {});
    });
  }

  @override
  void didUpdateWidget(RecentScreen old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible) _loadMessages();
  }

  @override
  void dispose() {
    _messages?.cancel();
    super.dispose();
  }

  void _syncFeeds(List<Host> hosts) {
    final feeds = fleet.sync(hosts);
    if (feeds.length == _feeds.length &&
        [for (var i = 0; i < feeds.length; i++) identical(feeds[i], _feeds[i])].every((x) => x)) {
      return;
    }
    _feeds = feeds;
    _merged = Listenable.merge([...feeds, toastProblems]);
  }

  void _loadMessages({bool force = false}) {
    if (!mounted || !widget.visible) return;
    for (final f in _feeds) {
      if (f.loaded) f.refreshMessages(force: force);
    }
    _loadHandoffs();
    _loadCore();
    for (final f in _feeds) {
      if (f.loaded) f.refreshPrs([for (final (s, r) in f.chatAgents) if (s.cwd ?? r?.primaryCwd case final d?) d]);
    }
  }

  Future<void> _loadCore() => Future.wait([
        for (final f in _feeds)
          loadCoreAsks(AppScope.read(context), f.host).then((r) {
            f.setCoreAsks(r.$2.length);
            if (mounted) setState(() => _core[f.host.id] = r);
          }),
      ]);

  Future<void> _loadHandoffs() => Future.wait([
        for (final f in _feeds)
          f.api.queueHistory(null, limit: 20).then((items) {
            if (mounted) setState(() => _handoffs[f.host.id] = items);
          }, onError: (Object _) {}), // An offline host keeps its last messages.
      ]);

  Future<void> _refresh() async {
    await Future.wait([for (final f in _feeds) f.refresh()]);
    await Future.wait([for (final f in _feeds) f.refreshMessages(force: true), _loadHandoffs(), _loadCore()]);
  }

  String _key(Host host, Seat seat) => '${host.id}|${chatKey(seat)}';

  /// Reads [seat]'s ask from its cached log when it's new or its log moved.
  void _wantPending(HostFeed f, Seat seat) {
    final key = _key(f.host, seat);
    final sig = '${seat.needsInputReason}|${seat.waitingSince}|${f.lastMessages[chatKey(seat)]?.at}';
    if (_pendingFor[key] == sig) return;
    _pendingFor[key] = sig;
    PendingAsk.load(f.host, seat).then((p) {
      if (mounted && _pendingFor[key] == sig) setState(() => _pending[key] = p);
    });
  }

  /// The card was answered and the seat still reports that ask: hidden until it asks something else.
  bool _justAnswered(String key, Seat seat) {
    final a = _answered[key];
    if (a == null) return false;
    if (askMoved(seat, a.$2, a.$1) || DateTime.now().difference(a.$1) > const Duration(seconds: 30)) {
      _answered.remove(key);
      return false;
    }
    return true;
  }

  void _openSeat(Host host, String rigName, Seat seat, {bool chat = false}) {
    useHost(context, host);
    detailNavigator(context).push(MaterialPageRoute(
      builder: (_) => chat && seat.isClaude
          ? ChatScreen(rigName: rigName, seat: seat)
          : TerminalScreen(target: SeatTarget(rigName, seat)),
    ));
  }

  void _openLoose(HostFeed f, LooseAgent a, {bool terminal = false}) {
    useHost(context, f.host);
    final nav = detailNavigator(context);
    if (terminal) {
      nav.push(MaterialPageRoute(
          builder: (_) => TerminalScreen(target: SeatTarget('no rig', a.toSeat()))));
    } else {
      openLooseAgent(nav, a, f.rigs);
    }
  }

  static String? _folder(String? cwd) =>
      cwd == null ? null : folderName(cwd);

  String? _lastSaid(HostFeed f, Seat s) => switch (f.lastMessages[chatKey(s)]) {
        final m? when !m.fromUser && m.text.trim().isNotEmpty => m.text,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    _syncFeeds(store.hosts);
    final k = Tokens.of(context);
    return Scaffold(
      body: ListenableBuilder(
        listenable: _merged,
        builder: (context, _) {
          final now = DateTime.now();
          final feeds = _feeds;
          final many = feeds.length > 1;

          // The same list the tab badge counts.
          final entries = <(String, Widget Function(bool expanded, bool selected, VoidCallback? toggle))>[];
          for (final f in feeds) {
            for (final item in f.needsYouItems) {
              if (item.action case final i?) {
                entries.add(('attention|${f.host.id}|${i.hashCode}', (_, __, ___) => _attentionCard(f, i, many)));
                continue;
              }
              final s = item.seat ?? item.loose!.toSeat();
              final key = _key(f.host, s);
              if (_justAnswered(key, s)) continue;
              _wantPending(f, s);
              entries.add((
                key,
                (open, selected, toggle) => item.seat != null
                    ? _seatCard(f, item.rig!, s, many, open, selected, toggle)
                    : _looseCard(f, item.loose!, s, many, open, selected, toggle)
              ));
            }
          }

          // Structured questions follow the permission cards; a host that can't show them says why in one line.
          for (final f in feeds) {
            final app = _core[f.host.id]?.$1;
            final listed = _core[f.host.id]?.$2 ?? const <CoreAsk>[];
            final shown = [...listed, for (final t in _tracked.entries) if (t.key.startsWith('${f.host.id}|') && !listed.any((a) => t.key == '${f.host.id}|${a.requestId}')) t.value];
            for (final a in shown) {
              if (!_askOrder.contains('${f.host.id}|${a.requestId}')) _askOrder.add('${f.host.id}|${a.requestId}');
            }
            shown.sort((a, b) => _askOrder.indexOf('${f.host.id}|${a.requestId}').compareTo(_askOrder.indexOf('${f.host.id}|${b.requestId}')));
            for (final a in shown) {
              entries.add((
                'ask|${f.host.id}|${a.requestId}',
                (_, __, ___) => Padding(
                    key: ValueKey('pad|${f.host.id}|${a.requestId}'),
                    padding: const EdgeInsets.only(bottom: 12),
                    child: CoreAskCard(
                      key: ValueKey('ask|${f.host.id}|${a.requestId}'),
                      ask: a,
                      where: many ? f.host.name : null,
                      onSubmit: app == null || app.state != CoreAppState.ready
                          ? null
                          : (answer) async {
                              final r = await submitCoreAnswer(AppScope.read(context), f.host, a, answer);
                              if (r.outcome == AnswerOutcome.recorded && r.complete) _tracked['${f.host.id}|${a.requestId}'] = a;
                              return r;
                            },
                      onChanged: _loadCore,
                      loadSaved: () => savedCoreAnswer(AppScope.read(context), f.host, a),
                    ))
              ));
            }
          }
          // An answered card stays on screen but is no longer waiting: the counts leave it out, as the badge does.
          final waiting = entries.length - [for (final f in feeds) for (final t in _tracked.keys) if (t.startsWith('${f.host.id}|') && !(_core[f.host.id]?.$2 ?? const <CoreAsk>[]).any((a) => t == '${f.host.id}|${a.requestId}')) t].length;
          final coreNote = [for (final f in feeds) if (_core[f.host.id] case (final app, _)? when app.state == CoreAppState.noPerson || app.state == CoreAppState.failed) (f, app)].firstOrNull;
          final handoffs = ([
            for (final f in feeds)
              for (final i in _handoffs[f.host.id] ?? const <QueueItem>[]) (i, f)
          ]..sort((a, b) => (b.$1.created ?? DateTime(0)).compareTo(a.$1.created ?? DateTime(0))))
              .take(20);
          final keys = [for (final e in entries) e.$1];
          final openKey = keys.contains(_open) ? _open : (_open == '' ? '' : keys.firstOrNull);
          Widget listFor(List<Widget> cards) => RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                  children: [
                    if (coreNote case (final f, final app)) CoreAppNote(app, host: many ? f.host.name : null),
                    if (entries.isNotEmpty) ...[
                      _label(k, 'Needs you · $waiting', shape: Status.needsYou),
                      ...cards,
                      const SizedBox(height: 6),
                    ],
                    // Problems the app toasted, still here after the toast went.
                    if (toastProblems.value case final problems when problems.isNotEmpty) ...[
                      _label(k, 'Problems · ${problems.length}', shape: Status.failed),
                      BorderedList(children: [
                        for (final p in problems)
                          RowTile(
                            leading: const StatusShape(Status.failed, size: 10, semantics: false),
                            title: p.message,
                            meta: agoPhrase(p.at, now),
                            minHeight: 48,
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              if (p.action case final a?)
                                TextButton(
                                  onPressed: () {
                                    toastProblems.value = [for (final q in toastProblems.value) if (q != p) q];
                                    p.onAction?.call();
                                  },
                                  child: Text(a),
                                ),
                              IconButton(
                                tooltip: 'Clear',
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () =>
                                    toastProblems.value = [for (final q in toastProblems.value) if (q != p) q],
                              ),
                            ]),
                          ),
                      ]),
                      const SizedBox(height: 18),
                    ],
                    if (entries.isEmpty && toastProblems.value.isEmpty && handoffs.isEmpty && !feeds.every((f) => f.loaded))
                      Padding(
                        padding: const EdgeInsets.all(28),
                        child: Center(child: Text('Loading…', textAlign: TextAlign.center, style: TextStyle(color: k.muted))),
                      ),
                    if (handoffs.isNotEmpty) ...[
                      _label(k, 'Handoffs'),
                      for (final (i, f) in handoffs)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: RigChatMessage(
                            item: i,
                            withRigs: true,
                            onTap: () {
                              useHost(context, f.host);
                              showHandoff(context, i);
                            },
                          ),
                        ),
                    ],
                  ],
                ),
              );
          return Column(children: [
            if (widget.column)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 12, 0),
                child: Row(children: [
                  Text('INBOX · $waiting', style: mono(context, size: 12, color: k.muted).copyWith(fontWeight: FontWeight.w600, letterSpacing: 1)),
                  const Spacer(),
                  TextButton(onPressed: () => inboxRequests.value++, child: const Text('Open ›')),
                ]),
              )
            else
              PageHeader(title: waiting == 0 ? 'Inbox' : 'Inbox $waiting'),
            Expanded(
              child: entries.isEmpty && coreNote == null && toastProblems.value.isEmpty && handoffs.isEmpty && feeds.every((f) => f.loaded)
                  ? const EmptyNote('Nothing needs you', 'Agents that wait for an answer or a permission show up here.')
                  : LayoutBuilder(builder: (context, box) {
                // A phone opens an item in place; a wide window lists them on the left and shows the open one on the right.
                if (box.maxWidth < 760) {
                  return PageColumn(
                    child: listFor([
                      for (final (key, card) in entries)
                        card(key == openKey, false, () => setState(() => _open = key == openKey ? '' : key)),
                    ]),
                  );
                }
                final shown = [for (final e in entries) if (e.$1 == (openKey == '' ? keys.firstOrNull : openKey)) e].firstOrNull;
                return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(
                    width: 380,
                    child: listFor([
                      for (final (key, card) in entries) card(false, key == shown?.$1, () => setState(() => _open = key)),
                    ]),
                  ),
                  VerticalDivider(width: 1, color: k.border),
                  Expanded(
                    child: shown == null
                        ? Center(child: Text('Select an item', style: TextStyle(color: k.muted)))
                        : SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                            child: shown.$2(true, false, null),
                          ),
                  ),
                ]);
              }),
            ),
          ]);
        },
      ),
    );
  }

  /// The kit's section label, as on every other page, with the state's shape before it.
  Widget _label(Tokens k, String text, {Status? shape, Widget? trailing}) => SectionLabel(text,
      leading: shape == null ? null : StatusShape(shape, size: 10, semantics: false), trailing: trailing);

  Widget _seatCard(HostFeed f, RigWithSeats r, Seat s, bool many, bool expanded, bool selected, VoidCallback? toggle) {
    final key = _key(f.host, s);
    final pod = s.podNamespace ?? (s.logicalId.contains('.') ? s.logicalId.substring(0, s.logicalId.indexOf('.')) : null);
    final cwd = s.cwd ?? r.primaryCwd;
    final where = [
      [f.host.rigLabel(r.rig.name), if (pod != null) pod, if (_folder(r.primaryCwd ?? s.cwd) case final p?) p].join(' › '),
      if (many) f.host.name,
    ].join(' · ');
    return NeedsYouCard(
      key: ValueKey(key),
      host: f.host,
      seat: s,
      where: where,
      age: s.waitingSince,
      pending: _pending[key],
      lastSaid: _lastSaid(f, s),
      branch: f.prs[cwd]?.headRef,
      onTerminal: () => _openSeat(f.host, r.rig.name, s),
      onChat: s.isClaude ? () => _openSeat(f.host, r.rig.name, s, chat: true) : null,
      onAnswered: () => setState(() => _answered[key] = (DateTime.now(), askSig(s))),
      expanded: expanded,
      selected: selected,
      onToggle: toggle,
    );
  }

  Widget _looseCard(HostFeed f, LooseAgent a, Seat s, bool many, bool expanded, bool selected, VoidCallback? toggle) {
    final key = _key(f.host, s);
    return NeedsYouCard(
      key: ValueKey(key),
      host: f.host,
      seat: s,
      loose: a,
      where: ['no rig › ${a.project ?? 'agent'}', if (many) f.host.name].join(' · '),
      age: a.since ?? a.heardAt,
      pending: _pending[key],
      lastSaid: _lastSaid(f, s),
      branch: f.prs[a.cwd]?.headRef,
      onTerminal: a.inTmux ? () => _openLoose(f, a, terminal: true) : null,
      onChat: () => _openLoose(f, a),
      onAnswered: () => setState(() => _answered[key] = (DateTime.now(), askSig(s))),
      expanded: expanded,
      selected: selected,
      onToggle: toggle,
    );
  }

  Widget _attentionCard(HostFeed f, AttentionItem i, bool many) {
    final k = Tokens.of(context);
    final role = i.asker?.split('@').first;
    final rigName = i.asker != null && i.asker!.contains('@') ? i.asker!.split('@').last : null;
    final where = [
      [if (rigName != null) rigName, if (i.projectRoot case final root?) folderName(root)].join(' › '),
      if (many) f.host.name,
    ].where((s) => s.isNotEmpty).join(' · ');
    final wants = switch (i.answerVerb) {
      'answer' => 'asked you something',
      'approve' => 'needs approval',
      'resolve' => 'is blocked',
      _ => 'needs you',
    };
    final target = attentionTarget(f.rigs, i);
    Widget link(String label, VoidCallback on) => TextButton(
          onPressed: on,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            foregroundColor: k.ink,
            textStyle: const TextStyle(
                fontFamily: fontSans, fontSize: 12, fontWeight: FontWeight.w600, decoration: TextDecoration.underline)).merge(compactAction),
          child: Text(label),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Panel(
        borderColor: k.accent,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text.rich(TextSpan(children: [
                TextSpan(text: role ?? 'A seat', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                TextSpan(
                    text: '  $wants', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: k.muted)),
              ])),
            ),
            if (i.at != null) Text(ago(i.at), style: mono(context, size: 11, color: k.muted)),
          ]),
          if (where.isNotEmpty) Text(where, style: TextStyle(fontSize: 12, color: k.muted)),
          const SizedBox(height: 10),
          Text(i.summary, style: const TextStyle(fontSize: 14, height: 1.45)),
          const SizedBox(height: 4),
          if (target case (final rig, final seat))
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              link('Terminal', () => _openSeat(f.host, rig, seat)),
              if (seat.isClaude) ...[
                const SizedBox(width: 10),
                link('Open in chat ›', () => _openSeat(f.host, rig, seat, chat: true)),
              ],
            ]),
        ]),
      ),
    );
  }
}

/// Asks for a free-text reply to a waiting seat; the text, or null.
Future<String?> askReply(BuildContext context, String session) =>
    inputSheet(context, title: 'Reply to $session', action: 'Send', lines: 2);
