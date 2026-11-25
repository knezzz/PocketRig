import 'package:flutter/material.dart';

import '../../data/fleet.dart' show fleet;
import '../../main.dart';
import '../../models.dart';
import '../common.dart';
import '../send_guard.dart';
import '../kit.dart';
import '../theme.dart';

/// The rig's chat room (`rig chatroom`): a shared board its seats post to.
/// Posting here wakes nobody; seats read it when they look.
class RigRoomScreen extends StatefulWidget {
  const RigRoomScreen({super.key, required this.rig});
  final Rig rig;
  @override
  State<RigRoomScreen> createState() => _RigRoomScreenState();
}

class _RigRoomScreenState extends State<RigRoomScreen> with Polling {
  List<RoomMessage>? _messages;
  String? _error;
  bool _sending = false;
  final _text = TextEditingController();

  @override
  Duration get every => const Duration(seconds: 15);
  @override
  bool wants(RigEvent e) => e.type == 'chat.message' && e.rigId == widget.rig.id;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Future<void> load() async {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    try {
      final m = await api.roomHistory(widget.rig.id);
      if (mounted) {
        setState(() {
          _messages = m;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _send() async {
    final api = AppScope.clientOf(context);
    final body = _text.text.trim();
    if (api == null || body.isEmpty) return;
    setState(() => _sending = true);
    try {
      await api.roomSend(widget.rig.id, body);
      _text.clear();
      await load();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final msgs = _messages;
    return Scaffold(
      body: Column(children: [
        PageHeader(overline: widget.rig.name, title: 'Room'),
        if (_error != null) ErrorBanner(_error!, margin: const EdgeInsets.fromLTRB(16, 8, 16, 0)),
        Expanded(
          child: msgs == null
              ? (_error == null ? const Center(child: CircularProgressIndicator()) : const SizedBox.shrink())
              : msgs.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('Nothing in ${widget.rig.name}\'s room yet. Seats post here with rig chatroom.',
                            textAlign: TextAlign.center, style: TextStyle(color: k.muted)),
                      ),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                      itemCount: msgs.length,
                      itemBuilder: (context, i) => _Message(msgs[msgs.length - 1 - i]),
                    ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(hintText: 'Post to the room (wakes nobody)'),
                ),
              ),
              IconButton(
                tooltip: 'Post',
                onPressed: _sending ? null : _send,
                icon: const Icon(Icons.send),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.m);
  final RoomMessage m;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: m.sender.split('@').first, style: TextStyle(color: k.ink, fontWeight: FontWeight.w600)),
              if (m.topic != null) TextSpan(text: '  #${m.topic}'),
              if (m.at != null) TextSpan(text: '  ·  ${ago(m.at)}'),
            ]),
            style: TextStyle(fontSize: 12, color: k.muted),
          ),
        ),
        Panel(child: SelectableText(m.body, style: TextStyle(fontSize: 14, height: 1.4, color: k.ink))),
      ]),
    );
  }
}

/// `rig broadcast --rig`: types one message into every seat of [rig], then
/// says which seats didn't get it.
Future<void> broadcastToRig(BuildContext context, Rig rig) async {
  final api = AppScope.clientOf(context);
  if (api == null) return;
  final text = await inputSheet(context,
      title: 'Message every seat in ${rig.name}',
      helper: 'Typed into each seat\'s prompt, like rig broadcast. Busy seats get it when they finish.',
      action: 'Send to all',
      lines: 3,
      capitalization: TextCapitalization.sentences);
  if (text == null || text.trim().isEmpty || !context.mounted) return;
  try {
    // A seat with a question or dialog open would take the message as its answer: those are skipped and named.
    final host = AppScope.read(context).active;
    final seats = host == null ? null : fleet.feedFor(host).rigs.where((r) => r.rig.id == rig.id).firstOrNull?.seats;
    final live = [for (final s in seats ?? const <Seat>[]) if (s.isAgent && s.sessionName != null && s.state != SeatState.stopped) s];
    // Seats we can't list can't be checked: ask, never broadcast unchecked.
    if (seats == null && (!await confirmUnchecked(context) || !context.mounted)) return;
    final open = host == null ? const <Seat>{} : await seatsWithOpenQuestion(host, live);
    final asking = [for (final s in live) if (open.contains(s)) s];
    if (!context.mounted) return;
    String names(Iterable<Seat> l) => l.map((s) => s.logicalId).join(', ');
    if (asking.isEmpty) {
      final out = await api.broadcast(rig.name, text.trim());
      final failed = out.where((o) => !o.ok).toList();
      if (!context.mounted) return;
      toast(
          context,
          failed.isEmpty
              ? 'Sent to ${out.length} seat${out.length == 1 ? '' : 's'}'
              : 'Sent to ${out.length - failed.length} of ${out.length}. Not sent: '
                  '${failed.map((o) => '${o.session.split('@').first}${o.error == null ? '' : ' (${o.error})'}').join(', ')}');
      return;
    }
    final targets = [for (final s in live) if (!asking.contains(s)) s];
    final failed = <Seat>[];
    for (final s in targets) {
      try {
        await api.send(s.sessionName!, text.trim());
      } catch (_) {
        failed.add(s);
      }
    }
    if (!context.mounted) return;
    toast(
        context,
        [
          targets.isEmpty ? 'Nothing sent' : 'Sent to ${targets.length - failed.length} of ${targets.length} seat${targets.length == 1 ? '' : 's'}',
          'Skipped, showing a question: ${names(asking)}',
          if (failed.isNotEmpty) 'Not sent: ${names(failed)}',
        ].join('. '));
  } catch (e) {
    if (context.mounted) toast(context, e.toString());
  }
}

/// Repeating reminders for [rig]'s seats (`rig watchdog`, periodic-reminder):
/// the active ones, add one, stop one.
class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key, required this.rig, required this.seats});
  final Rig rig;
  final List<Seat> seats;
  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> with Polling {
  List<WatchdogJob>? _jobs;
  String? _error;

  @override
  Duration get every => const Duration(seconds: 30);
  @override
  bool wants(RigEvent e) => e.type.startsWith('watchdog.job_');

  @override
  Future<void> load() async {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    try {
      final all = await api.watchdogJobs();
      if (mounted) {
        setState(() {
          _jobs = [
            for (final j in all)
              if (j.state == 'active' && j.target.endsWith('@${widget.rig.name}')) j
          ];
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _add() async {
    final api = AppScope.clientOf(context);
    final sessions = [
      for (final s in widget.seats)
        if (s.isAgent && s.sessionName != null) s.sessionName!
    ];
    if (api == null || sessions.isEmpty) return;
    final r = await showModalBottomSheet<(String, String, Duration)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _NewReminder(sessions),
    );
    if (r == null || !mounted) return;
    try {
      await api.addReminder(r.$1, r.$2, r.$3);
      if (mounted) toast(context, 'Reminder set for ${r.$1.split('@').first}');
      await load();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  Future<void> _stop(WatchdogJob j) async {
    final api = AppScope.clientOf(context);
    if (api == null ||
        !await confirmSheet(context,
            title: 'Stop this reminder?',
            body: j.isReminder ? (j.message ?? '') : 'This is OpenRig\'s own ${j.policy} check for ${j.target}.',
            action: 'Stop') ||
        !mounted) {
      return;
    }
    try {
      await api.stopWatchdog(j.id);
      await load();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final jobs = _jobs;
    return Scaffold(
      body: Column(children: [
        PageHeader(overline: widget.rig.name, title: 'Reminders'),
        Expanded(
          child: RefreshIndicator(
            onRefresh: load,
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 28), children: [
              if (_error != null) ErrorBanner(_error!, margin: const EdgeInsets.only(bottom: 12)),
              if (jobs == null && _error == null) const LinearProgressIndicator(),
              if (jobs != null && jobs.isEmpty)
                Text('No reminders for this rig\'s seats.', style: TextStyle(color: k.muted, fontSize: 13)),
              if (jobs != null && jobs.isNotEmpty)
                BorderedList(children: [
                  for (final j in jobs)
                    ListTile(
                      title: Text(j.isReminder ? (j.message ?? '(no message)') : j.policy,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text([
                        j.target.split('@').first,
                        'every ${everyLabel(j.intervalSeconds)}',
                        if (j.lastFired != null) 'last ${ago(j.lastFired)}',
                      ].join(' · ')),
                      trailing: IconButton(
                          tooltip: 'Stop', icon: const Icon(Icons.stop_circle_outlined), onPressed: () => _stop(j)),
                    ),
                ]),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.alarm_add, size: 20),
                label: const Text('New reminder'),
                style: sheetAction,
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// 900 → "15m", 7200 → "2h", 86400 → "1d".
String everyLabel(int seconds) => seconds % 86400 == 0
    ? '${seconds ~/ 86400}d'
    : seconds % 3600 == 0
        ? '${seconds ~/ 3600}h'
        : '${(seconds / 60).round()}m';

class _NewReminder extends StatefulWidget {
  const _NewReminder(this.sessions);
  final List<String> sessions;
  @override
  State<_NewReminder> createState() => _NewReminderState();
}

class _NewReminderState extends State<_NewReminder> {
  static const _intervals = [Duration(minutes: 30), Duration(hours: 1), Duration(hours: 2), Duration(hours: 4), Duration(days: 1)];
  late String _session = widget.sessions.first;
  Duration _every = const Duration(hours: 1);
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('New reminder', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _session,
              decoration: const InputDecoration(labelText: 'Seat'),
              items: [for (final s in widget.sessions) DropdownMenuItem(value: s, child: Text(s.split('@').first))],
              onChanged: (v) => setState(() => _session = v ?? _session),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              minLines: 2,
              maxLines: 4,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Message', hintText: 'Check the queue and report progress'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Segmented<Duration>(
              values: _intervals,
              labels: [for (final d in _intervals) everyLabel(d.inSeconds)],
              selected: _every,
              onChanged: (d) => setState(() => _every = d),
              semanticLabel: 'Repeat every',
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _text.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, (_session, _text.text.trim(), _every)),
              style: sheetAction,
              child: const Text('Set reminder'),
            ),
          ]),
        ),
      );
}
