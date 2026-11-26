import 'dart:async';
import 'package:flutter/material.dart';
import '../../api/daemon_route.dart';
import '../../api/openrig_client.dart';
import '../../data/fleet.dart' show fleet;
import '../../data/host_store.dart' show isDesktop;
import '../../data/host_setup.dart';
import '../../data/push.dart';
import '../../ssh/ssh_exec.dart';
import '../../main.dart';
import '../../models.dart';
import '../busy.dart';
import '../common.dart';
import '../host_color.dart';
import '../kit.dart';
import '../status_shape.dart';
import '../theme.dart';
import 'host_editor.dart' show HostEditor;

/// When each host's daemon last answered, in this run of the app: what an
/// offline host's line says ("offline · last seen 3h ago").
final hostLastSeen = <String, DateTime>{};

/// Turns [h] on or off app-wide (the host editor's Enabled switch), then tells its watcher (no kinds while off). The
/// watcher is best effort, as on save: the switch flips either way, and a toast says when push may go on. Runs one at
/// a time per host ([busyKeys]), so two watcher writes can't land out of order.
Future<void> setHostEnabled(BuildContext context, Host h, bool on) async {
  final store = AppScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  final k = Tokens.of(context);
  await exclusive('host:${h.id}', () async {
    await store.setEnabled(h, on);
    // Its feed stops polling (and its alerts go) at once, wherever the sidebar is.
    fleet.sync(store.hosts);
    if (h.ntfyTopic != null && h.privateKeyPem != null) {
      try {
        await writeWatcherConfig(h);
      } catch (e) {
        toastOn(messenger, k, 'Couldn\'t update the watcher on ${h.name}: $e. Push may continue until it can.');
      }
    }
  });
}

/// What a probe of a host's daemon found.
enum HostReach { checking, direct, viaSsh, offline }

/// A host in Settings: its state shape, name, and one honest line, with the
/// fix right there when it's degraded or offline. Tap to edit (the on/off switch is in the editor).
class HostStateTile extends StatefulWidget {
  const HostStateTile({super.key, required this.host, this.active = false, this.onSelect, this.selected = false});
  final Host host;
  final bool active;

  /// Settings' two-pane layout: a tap selects the host for the editor beside the list (else it pushes the editor), and
  /// the row carries the on/off switch.
  final VoidCallback? onSelect;
  final bool selected;
  @override
  State<HostStateTile> createState() => _HostStateTileState();
}

class _HostStateTileState extends State<HostStateTile> {
  HostReach _reach = HostReach.checking;
  int? _rigs;
  String? _version;
  bool _fixing = false;

  @override
  void initState() {
    super.initState();
    if (widget.host.enabled) _probe();
  }

  Future<void> _probe() async {
    final h = widget.host;
    final client = OpenRigClient.create(h);
    try {
      final ok = await client.healthy();
      int? rigs;
      String? version;
      if (ok) {
        hostLastSeen[h.id] = DateTime.now();
        version = await client.version();
        try {
          rigs = (await client.rigs()).where((r) => r.status != 'stopped').length;
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _reach = !ok ? HostReach.offline : (DaemonRoute.of(h).viaSsh ? HostReach.viaSsh : HostReach.direct);
        _rigs = rigs;
        _version = version;
      });
    } finally {
      client.close();
    }
  }

  void _retry({bool direct = false}) {
    if (direct) DaemonRoute.of(widget.host).resetToDirect();
    setState(() => _reach = HostReach.checking);
    _probe();
  }

  Future<void> _howToFix() async {
    final h = widget.host;
    final lan = sshOverLan(h);
    final go = await confirmSheet(context,
        title: lan ? 'Tailscale isn\'t answering' : 'The daemon isn\'t on the tailnet',
        body: lan
            ? 'The phone reached ${h.name} on the local network, so the daemon is reached through SSH: '
                'slower, and no live events. Turn Tailscale on on this device, then Retry direct.'
            : 'OpenRig listens on the Tailscale address only when Tailscale was up as the daemon started. '
                'Until then the app reaches it through SSH: slower, and no live events.\n\n'
                'Restarting the daemon binds the tailnet. Agents keep running in tmux.',
        action: lan ? null : 'Restart daemon',
        cancel: lan ? 'Close' : 'Cancel',
        destructive: false);
    if (!go || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final k = Tokens.of(context);
    setState(() => _fixing = true);
    try {
      await restartDaemon(h);
      toastOn(messenger, k, 'Restarted the daemon on ${h.name}');
      if (mounted) _retry(direct: true);
    } catch (e) {
      toastOn(messenger, k, 'Restart failed: $e');
    } finally {
      if (mounted) setState(() => _fixing = false);
    }
  }

  /// "online · live · 3 rigs · OpenRig 0.7.6": only what the probe found.
  String get _line {
    final h = widget.host;
    if (!h.enabled) return 'off · hidden, no notifications';
    switch (_reach) {
      case HostReach.checking:
        return 'checking…';
      case HostReach.direct:
        final live = AppScope.clientFor(h).live.connected.value;
        return [
          'online',
          if (live) 'live',
          if (_rigs != null) '$_rigs rig${_rigs == 1 ? '' : 's'}',
          if (_version != null) 'OpenRig $_version',
        ].join(' · ');
      case HostReach.viaSsh:
        return sshOverLan(h) ? 'online via local network · Tailscale didn\'t answer' : 'online via SSH · daemon isn\'t on the tailnet';
      case HostReach.offline:
        final seen = hostLastSeen[h.id];
        return seen == null ? 'offline' : 'offline · last seen ${agoPhrase(seen)}';
    }
  }

  Widget _small(String label, VoidCallback? onPressed) => OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          tapTargetSize: MaterialTapTargetSize.padded).merge(compactAction),
        child: Text(label),
      );

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final h = widget.host;
    final status = switch (_reach) {
      HostReach.checking => Status.idle,
      HostReach.direct => Status.working,
      HostReach.viaSsh => Status.degraded,
      HostReach.offline => Status.failed,
    };
    final line = _line;
    final off = !h.enabled;
    void edit() => widget.onSelect != null ? widget.onSelect!() : HostEditor.open(context, h);
    // Off is shown by the grey shape, the muted name and the line, never by fading the row: a faded switch reads as disabled.
    return Semantics(
      selected: widget.active || widget.selected,
      child: Material(
        color: widget.selected ? k.ground : Colors.transparent,
        child: InkWell(
        onTap: edit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 6), child: StatusShape(off ? Status.idle : status, semantics: false)),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                button: true,
                label: 'Edit host ${h.name}, $line${widget.active ? ', active' : ''}',
                excludeSemantics: true,
                onTap: edit,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    // The host's colour mark, the one the sidebar and the Rigs home show.
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: hostColor(h), borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(h.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: off ? k.muted : null)),
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Text(line, style: mono(context, size: 11, color: _reach == HostReach.offline && !off ? k.removed : k.muted)),
                ]),
              ),
            ),
            if (_reach == HostReach.offline && !off) ...[
              const SizedBox(width: 8),
              _small('Retry', () => _retry(direct: true)),
            ] else if (widget.onSelect == null && !off)
              const Padding(padding: EdgeInsets.only(top: 4), child: Chevron()),
            if (widget.onSelect != null && !(isDesktop && h.isLocal))
              Switch(value: h.enabled, onChanged: (on) async {
                await setHostEnabled(context, h, on);
                if (mounted) setState(() {});
              })
            else if (widget.onSelect != null)
              // This Mac has no switch (it can't be turned off here): keep its slot, so Retry ends where it does on every row.
              const Visibility(visible: false, maintainSize: true, maintainAnimation: true, maintainState: true, child: Switch(value: false, onChanged: null)),
          ]),
        ),
      ),
      ),
    ).withFix(
      show: _reach == HostReach.viaSsh && !off,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(36, 0, 14, 12),
        child: Wrap(spacing: 8, runSpacing: 4, children: [
          _small(_fixing ? 'Restarting…' : 'How to fix', _fixing ? null : _howToFix),
          _small('Retry direct', _fixing ? null : () => _retry(direct: true)),
        ]),
      ),
    );
  }
}

extension on Widget {
  /// This row, with [child] under it when [show].
  Widget withFix({required bool show, required Widget child}) =>
      show ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [this, child]) : this;
}
