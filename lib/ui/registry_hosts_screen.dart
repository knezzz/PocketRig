import 'dart:async';

import 'package:flutter/material.dart';

import '../data/registry_hosts.dart';
import '../models.dart';
import 'common.dart';
import 'kit.dart';
import 'theme.dart';

/// What `rig host doctor` said, in one line: ok, or its first problem
/// ("bearer token missing"). [out] is all it printed.
(bool, String) doctorVerdict(String out) {
  final lines = out.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  final bad = RegExp(r'^(FAIL|ERROR|ERR|✗|✕|×|x\s)|\b(fail(ed|s)?|error|missing|unreachable|refused|denied|timed out)\b',
      caseSensitive: false);
  final problem = lines.where((l) => !l.toLowerCase().startsWith('fix:') && bad.hasMatch(l)).firstOrNull;
  if (problem == null) return (true, 'ok');
  final clean = problem.replaceFirst(RegExp(r'^(FAIL|ERROR|ERR|✗|✕|×|x)\s*[:\-]?\s*', caseSensitive: false), '');
  return (false, clean.isEmpty ? problem : clean);
}

/// The last doctor result per registry entry ('<app host id>/<entry id>'),
/// kept while the app runs so the screen doesn't rerun it on every visit.
final _doctors = <String, (bool, String, DateTime)>{};

/// Pairings still waiting for approval on the other machine, by app host id.
/// They outlive the screen: you can leave, and a toast says how it went.
final _pairing = <String, Set<String>>{};

/// The OpenRig hosts one daemon knows (`~/.openrig/hosts.yaml`), which is how
/// one machine's rig reaches agents on another. Not the app's own host list.
class RegistryHostsScreen extends StatefulWidget {
  const RegistryHostsScreen({super.key, required this.host});
  final Host host;

  /// How long a doctor result counts as fresh.
  static const doctorFresh = Duration(minutes: 10);

  @override
  State<RegistryHostsScreen> createState() => _RegistryHostsScreenState();
}

class _RegistryHostsScreenState extends State<RegistryHostsScreen> {
  late final _rig = RegistryClient(widget.host);
  List<RegistryHost>? _hosts;
  String? _error;
  bool _busy = false;

  /// Entries whose doctor is running now.
  final _doctoring = <String>{};

  String _key(String id) => '${widget.host.id}/$id';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final hosts = await _rig.list();
      if (!mounted) return;
      setState(() {
        _hosts = hosts;
        _error = null;
      });
      unawaited(_doctorAll(hosts));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Runs doctor, one at a time, on entries with no fresh result.
  Future<void> _doctorAll(List<RegistryHost> hosts) async {
    final now = DateTime.now();
    for (final h in hosts) {
      final last = _doctors[_key(h.id)];
      if (h.selected || (last != null && now.difference(last.$3) < RegistryHostsScreen.doctorFresh)) continue;
      if (!mounted) return;
      await _runDoctor(h);
    }
  }

  /// Runs doctor on [h], keeps its verdict, and returns everything it printed.
  Future<String> _runDoctor(RegistryHost h) async {
    setState(() => _doctoring.add(h.id));
    String out;
    try {
      out = (await _rig.doctor(h.id)).trim();
      final (ok, line) = doctorVerdict(out);
      _doctors[_key(h.id)] = (ok, line, DateTime.now());
    } catch (e) {
      out = '$e';
      _doctors[_key(h.id)] = (false, 'couldn\'t run: ${'$e'.split('\n').first}', DateTime.now());
    }
    if (mounted) setState(() => _doctoring.remove(h.id));
    return out;
  }

  /// Runs one rig command, shows what it said when it failed, then reloads.
  Future<bool> _do(Future<Object?> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
      await _load();
      return true;
    } catch (e) {
      _say('$e');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String m) {
    if (mounted) toast(context, m);
  }

  Future<void> _form({RegistryHost? edit}) async {
    final r = await showDialog<_Entry>(context: context, builder: (_) => _EntryDialog(edit: edit));
    if (r == null) return;
    await _do(() => edit == null
        ? _rig.add(
            id: r.id,
            transport: r.transport,
            target: r.target,
            user: r.user,
            url: r.url,
            bearerEnv: r.bearerEnv,
            bearerFile: r.bearerFile,
            notes: r.notes)
        : _rig.edit(edit, target: r.target, user: r.user, url: r.url, notes: r.notes));
  }

  /// Starts pairing and returns at once: it waits for approval in the
  /// background, and a toast says how it went, here or wherever you are.
  Future<void> _pair() async {
    final r = await showDialog<(String, String)>(context: context, builder: (_) => const _PairDialog());
    if (r == null || !mounted) return;
    final (address, id) = r;
    final messenger = ScaffoldMessenger.of(context);
    final k = Tokens.of(context);
    final pending = _pairing.putIfAbsent(widget.host.id, () => {})..add(address);
    setState(() {});
    toastOn(messenger, k, 'Waiting for approval on $address. You can leave this screen.');
    try {
      await _rig.pair(address, id: id);
      toastOn(messenger, k, 'Paired with $address');
      if (mounted) unawaited(_load());
    } catch (e) {
      toastOn(messenger, k, 'Pairing with $address failed: ${'$e'.split('\n').first}');
    } finally {
      pending.remove(address);
      if (mounted) setState(() {});
    }
  }

  Future<void> _remove(RegistryHost h) async {
    final yes = await confirmSheet(context,
        title: 'Remove ${h.id}?',
        body: 'Deletes only this registry entry on ${widget.host.name}. Credential files stay where they are.',
        action: 'Remove');
    if (yes) await _do(() => _rig.remove(h.id));
  }

  Future<void> _doctor(RegistryHost h) async {
    final out = await _runDoctor(h);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Doctor: ${h.id}'),
        content: SingleChildScrollView(child: SelectableText(out, style: mono(context, size: 12))),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );
  }

  Widget _row(BuildContext context, RegistryHost h) {
    final k = Tokens.of(context);
    final doc = _doctors[_key(h.id)];
    final running = _doctoring.contains(h.id);
    final (String? line, Color color) = running
        ? ('running doctor…', k.muted)
        : doc == null
            ? (null, k.muted)
            : doc.$1
                ? ('doctor ok · ${agoPhrase(doc.$3)}', k.added)
                : ('doctor: ${doc.$2}', k.removed);
    return Semantics(
      container: true,
      child: RowTile(
        minHeight: 64,
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        onTap: () => _form(edit: h),
        trailing: IconButton(
          tooltip: '${h.id} actions',
          icon: const Icon(Icons.more_horiz),
          onPressed: () => showActionSheet(context, h.id, [
            if (!h.selected) (Icons.check_circle_outline, 'Make current', null, () => _do(() => _rig.select(h.id))),
            (Icons.health_and_safety_outlined, 'Run doctor', null, () => _doctor(h)),
            (Icons.edit_outlined, 'Edit', null, () => _form(edit: h)),
          ], danger: [
            ('Remove…', Icons.delete_outline, () => _remove(h)),
          ]),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text(h.id, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
            if (h.selected) ...[
              const SizedBox(width: 6),
              const Pill('current', bold: false),
            ],
          ]),
          const SizedBox(height: 2),
          Text('${h.transport} · ${h.where}${h.notes == null ? '' : ' · ${h.notes}'}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 11)),
          if (line != null)
            Text(line,
                style: TextStyle(
                    fontSize: 12,
                    color: color)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final hosts = _hosts;
    final pairing = _pairing[widget.host.id] ?? const <String>{};
    return Scaffold(
      body: Column(children: [
        PageHeader(title: 'Machines on ${widget.host.name}'),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Panel(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.info_outline, size: 16, color: k.muted),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Machines this daemon\'s rigs can reach. These are not the hosts PocketRig connects to; '
                        'those are in Settings.',
                        style: TextStyle(fontSize: 13, color: k.muted, height: 1.4),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
                if (_error != null)
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_error!, style: TextStyle(color: k.removed)),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ])
                else if (hosts == null)
                  const Center(child: CircularProgressIndicator())
                else if (hosts.isEmpty)
                  Text('No machines registered yet.', style: TextStyle(color: k.muted))
                else
                  BorderedList(children: [for (final h in hosts) _row(context, h)]),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => _form(),
                      child: const Text('+ Add'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _pair,
                      child: const Text('Pair a machine…'),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                for (final a in pairing)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Waiting for approval on $a…', style: TextStyle(fontSize: 12, color: k.muted))),
                    ]),
                  ),
                Text(
                  'Pairing waits for approval on the other machine. You can leave this screen; '
                  'we\'ll toast when it\'s approved.',
                  style: TextStyle(fontSize: 12, color: k.muted, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

class _Entry {
  _Entry(this.id, this.transport, {this.target, this.user, this.url, this.bearerEnv, this.bearerFile, this.notes});
  final String id, transport;
  final String? target, user, url, bearerEnv, bearerFile, notes;
}

/// Add (no [edit]) or edit an entry. On edit the id and transport are fixed.
class _EntryDialog extends StatefulWidget {
  const _EntryDialog({this.edit});
  final RegistryHost? edit;

  @override
  State<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<_EntryDialog> {
  late String _transport = widget.edit?.transport ?? 'ssh';
  late final _id = TextEditingController(text: widget.edit?.id);
  late final _target = TextEditingController(text: widget.edit?.target);
  late final _user = TextEditingController(text: widget.edit?.user);
  late final _url = TextEditingController(text: widget.edit?.url);
  late final _env = TextEditingController(text: widget.edit?.bearerEnv);
  late final _file = TextEditingController(text: widget.edit?.bearerFile);
  late final _notes = TextEditingController(text: widget.edit?.notes);

  @override
  void dispose() {
    for (final c in [_id, _target, _user, _url, _env, _file, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(TextEditingController c, String label, {bool enabled = true, String? hint}) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextField(
          controller: c,
          enabled: enabled,
          autocorrect: false,
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final editing = widget.edit != null;
    final ssh = _transport == 'ssh';
    return AlertDialog(
      title: Text(editing ? 'Edit ${widget.edit!.id}' : 'Add a host'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!editing)
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'ssh', label: Text('SSH')), ButtonSegment(value: 'http', label: Text('HTTP'))],
              selected: {_transport},
              onSelectionChanged: (s) => setState(() => _transport = s.first),
            ),
          _field(_id, 'Id', enabled: !editing),
          if (ssh) ...[_field(_target, 'Target', hint: 'name, ssh alias or IP'), _field(_user, 'User (optional)')] else ...[
            _field(_url, 'Daemon URL', hint: 'http://host:7433'),
            // Pointers only: the name of an env var or the path of a file, never the token.
            if (!editing) ...[
              _field(_env, 'Bearer env var name (optional)'),
              _field(_file, 'Bearer file path (optional)'),
            ],
          ],
          _field(_notes, 'Notes (optional)'),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ListenableBuilder(
          listenable: _id,
          builder: (context, _) => TextButton(
            onPressed: _id.text.trim().isEmpty
                ? null
                : () => Navigator.pop(
                      context,
                      _Entry(_id.text.trim(), _transport,
                          target: _target.text, user: _user.text, url: _url.text, bearerEnv: _env.text, bearerFile: _file.text, notes: _notes.text),
                    ),
            child: Text(editing ? 'Save' : 'Add'),
          ),
        ),
      ],
    );
  }
}

class _PairDialog extends StatefulWidget {
  const _PairDialog();
  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  final _addr = TextEditingController();
  final _id = TextEditingController();

  @override
  void dispose() {
    _addr.dispose();
    _id.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Pair with a host'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _addr,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Address', hintText: 'host:7433 or http://host:7433'),
          ),
          TextField(controller: _id, autocorrect: false, decoration: const InputDecoration(labelText: 'Id (optional)')),
          const SizedBox(height: 8),
          const Text('Someone has to approve it on the other machine. It waits up to 10 minutes in the background and can\'t be cancelled once started.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ListenableBuilder(
            listenable: _addr,
            builder: (context, _) => TextButton(
              onPressed: _addr.text.trim().isEmpty ? null : () => Navigator.pop(context, (_addr.text.trim(), _id.text.trim())),
              child: const Text('Pair'),
            ),
          ),
        ],
      );
}
