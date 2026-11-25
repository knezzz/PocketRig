import 'dart:async';

import 'package:flutter/material.dart';

import '../api/openrig_client.dart';
import '../data/git_status.dart';
import '../data/rig_spec.dart';
import '../data/seat_poll.dart';
import '../main.dart';
import '../models.dart';
import 'check_row.dart';
import 'common.dart';
import 'desktop_shell.dart' show detailNavigator, shownDetailPane;
import 'kit.dart';
import 'rig_screen.dart';
import 'status_shape.dart';
import 'theme.dart';

/// [spec]'s rig name when started in [worktree]: the worktree after it, as
/// rig names are unique on the daemon.
String worktreeRigName(String spec, String worktree) => '$spec-${worktree.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}';

/// Opens the sheet that checks (`rig up --plan`) and starts a rig from [file].
Future<void> showLaunchSheet(
  BuildContext context, {
  required RigSpecFile file,
  required RigSpecSummary spec,
  required String projectName,
  List<Worktree> worktrees = const [],
  String? cwd,
  String? rigName,
}) {
  final sheet =
      LaunchSheet(file: file, spec: spec, projectName: projectName, worktrees: worktrees, cwd: cwd, rigName: rigName);
  // A dialog on the Mac: a bottom sheet across a wide window is all stretch and no content.
  return showDialogOrSheet<void>(context, child: sheet, dialogTop: 20);
}

class LaunchSheet extends StatefulWidget {
  const LaunchSheet({
    super.key,
    required this.file,
    required this.spec,
    required this.projectName,
    this.worktrees = const [],
    this.cwd,
    this.rigName,
  });
  final RigSpecFile file;
  final RigSpecSummary spec;
  final String projectName;

  /// The project's worktrees, main checkout first.
  final List<Worktree> worktrees;

  /// Absolute working folder; the project's folder when null.
  final String? cwd;
  final String? rigName;

  @override
  State<LaunchSheet> createState() => _LaunchSheetState();
}

class _LaunchSheetState extends State<LaunchSheet> {
  late String _cwd = widget.cwd ?? widget.file.projectPath;
  late final _name = TextEditingController(text: widget.rigName ?? widget.spec.name ?? '');
  bool _planning = false;
  LaunchResult? _plan;
  String? _error;

  // While starting: the daemon answers only once the launch is done, so the
  // seats are polled meanwhile.
  DateTime? _startedAt;
  LaunchResult? _result;
  List<Seat> _seats = const [];
  String? _rigId;
  Timer? _tick;
  Timer? _poll;

  bool get _starting => _startedAt != null && _result == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _check();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _poll?.cancel();
    _name.dispose();
    super.dispose();
  }

  String get _rigLabel => _name.text.trim().isEmpty ? (widget.spec.name ?? 'rig') : _name.text.trim();

  /// Null when it's the spec's own name, so the daemon uses that.
  String? get _rigNameArg {
    final n = _name.text.trim();
    return n.isEmpty || n == widget.spec.name ? null : n;
  }

  Worktree? get _worktree => widget.worktrees.where((w) => w.path == _cwd).firstOrNull;

  String _worktreeLabel(Worktree w) => identical(w, widget.worktrees.first) ? 'Main checkout' : (w.branch ?? w.name);

  Future<void> _check() async {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    setState(() {
      _planning = true;
      _error = null;
    });
    try {
      final r = await api.up(widget.file.path, cwd: _cwd, rigName: _rigNameArg, plan: true);
      if (!mounted) return;
      setState(() {
        _plan = r;
        if (!r.ok) _error = r.errors.isNotEmpty ? r.errors.join('\n') : (r.stages.isEmpty ? 'Plan ${r.status}' : null);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _planning = false);
    }
  }

  /// Outside the main checkout the rig gets the worktree's name after its own.
  void _useWorktree(Worktree w) {
    if (w.path == _cwd) return;
    final spec = widget.spec.name ?? 'rig';
    setState(() {
      _cwd = w.path;
      _name.text = identical(w, widget.worktrees.first) ? spec : worktreeRigName(spec, w.name);
    });
    _check();
  }

  Future<void> _start() async {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    final name = _rigLabel;
    // Closing the sheet doesn't stop the launch: these tell how it ended.
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final k = Tokens.of(context);
    setState(() {
      _startedAt = DateTime.now();
      _error = null;
      _seats = const [];
      _rigId = null;
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _poll = Timer.periodic(seatPollEvery, (_) => _pollSeats(api, name));
    try {
      final r = await api.up(widget.file.path, cwd: _cwd, rigName: _rigNameArg);
      if (!mounted) {
        _toastWhenClosed(messenger, nav, k, api, name, r);
        return;
      }
      await _pollSeats(api, name);
      if (!mounted) return;
      setState(() {
        if (r.ok) {
          _result = r;
          _rigId = r.rigId ?? _rigId;
          if (r.status == 'partial') _error = r.errors.isEmpty ? 'Some seats didn\'t start.' : r.errors.join('\n');
        } else {
          _startedAt = null;
          _error = r.errors.isEmpty ? 'Launch ${r.status}' : r.errors.join('\n');
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _startedAt = null;
          _error = e.toString();
        });
      } else {
        toastOn(messenger, k, '$name didn\'t start: $e');
      }
    } finally {
      _tick?.cancel();
      _poll?.cancel();
    }
  }

  /// The sheet was closed while the rig started: say how it ended, with Open.
  void _toastWhenClosed(
      ScaffoldMessengerState messenger, NavigatorState nav, Tokens k, OpenRigClient api, String name, LaunchResult r) {
    if (!r.ok) {
      toastOn(messenger, k, '$name didn\'t start: ${r.errors.isEmpty ? r.status : r.errors.first}');
      return;
    }
    final id = r.rigId;
    toastOn(messenger, k, r.status == 'partial' ? '$name is up, but some seats didn\'t start' : '$name is up',
        kind: r.status == 'partial' ? ToastKind.problem : ToastKind.done,
        action: id == null ? null : 'Open', onAction: id == null ? null : () async {
      final rig = await api.rig(id);
      if (rig != null && nav.mounted) {
        unawaited((shownDetailPane() ?? nav).push(MaterialPageRoute<void>(builder: (_) => RigScreen(rig: rig, projectName: widget.projectName))));
      }
    });
  }

  Future<void> _pollSeats(OpenRigClient api, String name) async {
    try {
      final id = _rigId ?? (await api.rigs()).where((r) => r.name == name).firstOrNull?.id;
      if (id == null) return;
      final seats = await api.seats(id);
      if (mounted) {
        setState(() {
          _rigId = id;
          _seats = seats;
        });
      }
    } catch (_) {/* the next poll tries again */}
  }

  /// Starts a seat that failed to launch again, then watches it come up (the poll runs for a few minutes).
  final _retrying = <String>{};

  Future<void> _retry(Seat seat) async {
    final api = AppScope.clientOf(context);
    if (api == null || _retrying.contains(seat.logicalId)) return;
    setState(() => _retrying.add(seat.logicalId));
    final messenger = ScaffoldMessenger.of(context);
    final k = Tokens.of(context);
    try {
      await api.retrySeatLaunch(seat);
    } catch (e) {
      if (mounted) setState(() => _retrying.remove(seat.logicalId));
      toastOn(messenger, k, 'Couldn\'t retry ${seat.logicalId}: ${e is OpenRigException ? e.message : e}');
      return;
    }
    if (!mounted) return;
    final name = _rigLabel;
    await _pollSeats(api, name);
    if (mounted) setState(() => _retrying.remove(seat.logicalId));
    _poll?.cancel();
    var polls = 0;
    _poll = Timer.periodic(seatPollEvery, (t) {
      // Until nothing is starting any more, or it has been a few minutes.
      if (!mounted || ++polls > 60 || (polls > 2 && !_seats.any((s) => s.startupStatus == 'pending'))) {
        t.cancel();
        return;
      }
      _pollSeats(api, name);
    });
  }

  Future<void> _openRig() async {
    final api = AppScope.clientOf(context);
    final id = _rigId;
    if (api == null || id == null) return;
    final rig = await api.rig(id);
    if (!mounted || rig == null) return;
    final own = Navigator.of(context);
    // The desktop dialog sits on the root navigator, outside the detail pane, so ask for the pane directly.
    final target = shownDetailPane() ?? detailNavigator(context);
    own.pop();
    final route = MaterialPageRoute<void>(builder: (_) => RigScreen(rig: rig, projectName: widget.projectName));
    // The phone swaps the launching page; the desktop opens the rig in the detail pane beside the list.
    if (identical(target, own)) {
      unawaited(target.pushReplacement(route));
    } else {
      unawaited(target.push(route));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final k = Tokens.of(context);
    final launching = _startedAt != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${launching ? (_starting ? 'Starting' : 'Started') : 'Start'} ${widget.spec.name ?? 'rig'}',
                style: t.titleLarge?.copyWith(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(launching ? _whereLine : _seatLine, style: launching ? mono(context) : t.bodySmall?.copyWith(fontSize: 13)),
          ]),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            children: [
              if (_error != null) ErrorBanner(_error!, margin: const EdgeInsets.only(bottom: 16)),
              if (launching) ..._progress(context) else ..._form(context),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: k.divider))),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: SafeArea(top: false, child: _button()),
        ),
      ]),
    );
  }

  /// "worktree auth · feat/auth", or the folder: where the rig is starting.
  String get _whereLine {
    final w = _worktree;
    if (w == null || identical(w, widget.worktrees.firstOrNull)) {
      return [w == null ? displayPath(_cwd) : 'main checkout', if (w?.branch != null) w!.branch!].join(' · ');
    }
    return ['worktree ${w.name}', if (w.branch != null) w.branch!].join(' · ');
  }

  Widget _button() {
    final t = Theme.of(context).textTheme;
    if (_startedAt != null) {
      // Open as soon as the rig exists; it keeps starting either way.
      return Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => Navigator.of(context).maybePop(),
            style: OutlinedButton.styleFrom().merge(sheetAction),
            child: const Text('Close'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton(
            onPressed: _rigId != null ? _openRig : null,
            style: FilledButton.styleFrom().merge(sheetAction),
            child: Text(_result != null ? 'Open rig' : 'Open rig now'),
          ),
        ),
      ]);
    }
    final where = _worktree;
    final ready = !_planning && (_plan?.ok ?? false);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FilledButton.icon(
        onPressed: ready ? _start : null,
        style: FilledButton.styleFrom().merge(sheetAction),
        icon: const Icon(Icons.play_arrow_rounded, size: 20),
        label: Text(widget.worktrees.length > 1 && where != null ? 'Start in ${_worktreeLabel(where)}' : 'Start rig'),
      ),
      const SizedBox(height: 8),
      Text(
        ready || _plan == null
            ? 'First starts take 2–3 min. You can close this; it keeps starting.'
            : 'Start waits for the launch check to pass.',
        textAlign: TextAlign.center,
        style: t.bodySmall,
      ),
    ]);
  }

  /// "4 seats · 3 Claude Code, 1 Codex".
  String get _seatLine {
    final counts = <String, int>{};
    for (final p in widget.spec.pods) {
      for (final m in p.members) {
        final rt = SpecMember.runtimeLabel(m.runtime);
        counts[rt] = (counts[rt] ?? 0) + 1;
      }
    }
    final n = widget.spec.seatCount;
    final mix = counts.entries.map((e) => '${e.value} ${e.key}').join(', ');
    return '$n seat${n == 1 ? '' : 's'}${mix.isEmpty ? '' : ' · $mix'}';
  }

  List<Widget> _form(BuildContext context) {
    final k = Tokens.of(context);
    final t = Theme.of(context).textTheme;
    final plan = _plan;
    return [
      if (widget.worktrees.length > 1) ...[
        const SectionLabel('Where'),
        BorderedList(children: [
          for (final w in widget.worktrees)
            Semantics(
              inMutuallyExclusiveGroup: true,
              checked: w.path == _cwd,
              child: RowTile(
                minHeight: 56,
                leading: Icon(w.path == _cwd ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 20, color: w.path == _cwd ? k.ink : k.muted),
                title: _worktreeLabel(w),
                meta: displayPath(w.path),
                metaMono: true,
                onTap: _planning ? null : () => _useWorktree(w),
              ),
            ),
        ]),
        const SizedBox(height: 20),
      ] else ...[
        const SectionLabel('Folder'),
        Text(displayPath(_cwd), style: mono(context, size: 13, color: k.ink)),
        const SizedBox(height: 20),
      ],
      const SectionLabel('Rig name'),
      TextField(
        controller: _name,
        autocorrect: false,
        enabled: !_planning,
        style: mono(context, size: 13, color: k.ink),
        decoration: const InputDecoration(hintText: 'Rig name'),
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() => _plan = null),
        onSubmitted: (_) => _check(),
      ),
      const SizedBox(height: 20),
      SectionLabel(
        'Launch check',
        trailing: _planning
            ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : plan != null && plan.ok
                ? Text('Ready', style: t.bodySmall?.copyWith(color: k.added, fontWeight: FontWeight.w600))
                : TextButton(onPressed: _check, child: const Text('Check again')),
      ),
      if (plan == null && _planning) Text('Checking the spec on your computer…', style: t.bodySmall),
      for (final (stage, status, detail) in plan?.stages ?? const <(String, String, String?)>[])
        _planCheck(stage, status, detail),
    ];
  }

  List<Widget> _progress(BuildContext context) {
    final k = Tokens.of(context);
    final t = Theme.of(context).textTheme;
    final members = [
      for (final p in widget.spec.pods)
        for (final m in p.members) (p, m)
    ];
    Seat? seatOf(SpecPod p, SpecMember m) => _seats
        .where((s) => s.logicalId == '${p.id}.${m.id}' || s.logicalId == m.id || s.logicalId.endsWith('.${m.id}'))
        .firstOrNull;
    VoidCallback? retryOf(SpecPod p, SpecMember m) {
      final seat = seatOf(p, m);
      return seat != null && seat.launchFailed ? () => _retry(seat) : null;
    }

    // Why a seat did not launch: the node's recorded startup error, else what the launch reported for it.
    String? failedReason(SpecPod p, SpecMember m) {
      final seat = seatOf(p, m);
      if (seat?.latestError case final e? when seat!.launchFailed && e.isNotEmpty) return e;
      for (final id in ['${p.id}.${m.id}', m.id]) {
        if (_result?.failedSeats[id] case final e?) return e;
      }
      return _result?.failedSeats.entries.where((e) => e.key.endsWith('.${m.id}')).firstOrNull?.value;
    }

    final ready = members.where((pm) => seatOf(pm.$1, pm.$2)?.startupStatus == 'ready').length;
    final total = members.length;
    final busy = [
      for (final (p, m) in members)
        if (seatOf(p, m) case final s? when s.startupStatus != 'ready') m.id
    ];
    final elapsed = DateTime.now().difference(_startedAt!);
    final clock = '${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    final headline = _result != null
        ? (_result!.status == 'partial' ? '$_rigLabel partly started' : '$_rigLabel is running')
        : _rigId == null
            ? 'Setting up $_rigLabel'
            : busy.isEmpty
                ? 'Waiting for seats'
                : 'Starting ${busy.take(2).join(' and ')}${busy.length > 2 ? ' +${busy.length - 2}' : ''}';
    return [
      Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: k.fill, borderRadius: BorderRadius.circular(kRadius)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              Expanded(child: Text(headline, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
              ExcludeSemantics(child: Text(clock, style: mono(context, size: 13))),
            ]),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: _result != null ? 1 : (_rigId == null || total == 0 ? null : (ready + .5) / total),
                color: k.ink,
                backgroundColor: k.border,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _result != null
                  ? '$ready of $total seats ready'
                  : '$ready of $total seats ready · first starts often take 2–3 minutes',
              style: t.bodySmall,
            ),
          ]),
        ),
      ),
      const SizedBox(height: 22),
      const SectionLabel('Seats'),
      BorderedList(children: [
        for (final (p, m) in members)
          _SeatRow(
            member: m,
            seat: seatOf(p, m),
            done: _result != null,
            reason: failedReason(p, m),
            onRetry: retryOf(p, m),
            retrying: _retrying.contains(seatOf(p, m)?.logicalId),
          ),
      ]),
      if (_starting) ...[
        const SizedBox(height: 22),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline, size: 16, color: k.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text('You can close this. The rig keeps starting, and you\'ll get a toast when it\'s up.',
                style: t.bodySmall?.copyWith(fontSize: 13)),
          ),
        ]),
      ],
    ];
  }
}

/// One `rig up --plan` stage's plain name.
String stageLabel(String stage) => switch (stage) {
      'resolve_spec' => 'Spec is valid',
      'resolve_packages' => 'Packages resolved',
      'verify_runtimes' => 'Runtimes found',
      'services_plan' => 'Services planned',
      'import_rig' => 'Rig can be created',
      'execute_external_installs' => 'Installs',
      final s => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1).replaceAll('_', ' ')}',
    };

/// One `rig up --plan` stage as a check row: a mark, a plain name and the daemon's detail.
Widget _planCheck(String stage, String status, String? detail) {
  final bad = status == 'failed' || status == 'blocked' || status == 'error';
  final skipped = status == 'skipped';
  final extra = [if (skipped) 'skipped', if (bad && !skipped) status, if (detail != null) detail].join(' · ');
  return CheckRow(bad ? CheckState.bad : (skipped ? CheckState.off : CheckState.ok), stageLabel(stage),
      detail: extra, layout: CheckLayout.stacked);
}

/// A seat while its rig starts: waiting (not created yet), starting, ready,
/// needs you or failed, from the node's `startupStatus`.
class _SeatRow extends StatelessWidget {
  const _SeatRow({required this.member, required this.seat, required this.done, this.reason, this.onRetry, this.retrying = false});
  final SpecMember member;
  final Seat? seat;

  /// Why the seat did not launch, when it is known.
  final String? reason;

  /// Starts it again (a seat the daemon has, marked failed); null where there is nothing to retry.
  final VoidCallback? onRetry;

  /// Its launch is being asked for: Retry waits.
  final bool retrying;

  /// The launch finished: a seat still missing didn't start.
  final bool done;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final status = seat?.startupStatus;
    final needsReason = seat?.needsInputReason;
    final (Widget mark, String meta, Color? metaColor) = switch (status) {
      'ready' => (const CheckMark(CheckState.ok, size: 20), 'Ready', k.added),
      'attention_required' => (
          const SizedBox.square(dimension: 20, child: Center(child: StatusShape(Status.needsYou))),
          needsReason == null || needsReason.isEmpty ? 'Needs you' : 'Needs you: $needsReason',
          k.accent,
        ),
      'failed' => (const CheckMark(CheckState.bad, size: 20), reason == null ? 'Didn\'t start' : 'Didn\'t start: $reason', k.removed),
      _ when seat != null => (
          Semantics(
              label: 'Starting',
              child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: k.ink, backgroundColor: k.border))),
          'Starting…',
          k.ink,
        ),
      _ => (
          Semantics(
            label: 'Waiting',
            child: SizedBox.square(dimension: 20, child: CustomPaint(painter: DashedBorder(k.faint, radius: 10))),
          ),
          done ? 'Not started' : 'Waiting',
          null,
        ),
    };
    return RowTile(
      minHeight: 56,
      leading: mark,
      title: member.id,
      titleTrailing: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Text(SpecMember.runtimeLabel(member.runtime), style: TextStyle(fontSize: 12, color: k.muted)),
      ),
      meta: meta,
      metaColor: metaColor,
      trailing: onRetry == null
          ? null
          : OutlinedButton(
              onPressed: retrying ? null : onRetry,
              style: compactAction.merge(OutlinedButton.styleFrom(foregroundColor: k.removed, side: BorderSide(color: k.removed))),
              child: const Text('Retry', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
    );
  }
}
