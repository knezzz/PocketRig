import 'dart:async';
import 'dart:math';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../api/daemon_route.dart';
import '../../api/openrig_client.dart';
import '../../data/deep_link.dart';
import '../../data/host_setup.dart';
import '../../data/host_store.dart' show isDesktop;
import '../../data/push.dart';
import '../../ssh/host_keys.dart';
import '../../ssh/keygen.dart';
import '../../ssh/ssh_exec.dart';
import '../../main.dart';
import '../../models.dart';
import '../busy.dart';
import '../check_row.dart';
import '../common.dart';
import '../host_color.dart';
import 'colour_picker.dart';
import '../kit.dart';
import '../switch_row.dart';
import '../ssh_log_screen.dart';
import '../status_shape.dart';
import '../theme.dart';
import '../registry_hosts_screen.dart';
import 'host_state_tile.dart' show hostLastSeen, setHostEnabled;

part 'host_editor_rows.dart';

/// One health check's result: passed, failed, or not known yet.
enum _Verdict { ok, bad, unknown }

typedef _Health = (_Verdict, String);

/// Add or edit a host, in three parts: what you check (Health), what you do
/// once (Connection, SSH key), what you tune (Notify me about), then the
/// maintenance actions under Host tools. One Save, in the header.
class HostEditor extends StatefulWidget {
  const HostEditor({super.key, this.host, this.draft, this.onDone});

  static void open(BuildContext context, Host? host, {Host? draft}) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => HostEditor(host: host, draft: draft)));

  /// The saved host being edited; null to add one.
  final Host? host;

  /// A new host prefilled by the first-run steps (not saved yet).
  final Host? draft;

  /// Shown in Settings' right pane rather than pushed: what to do after Save or Remove (a pushed page pops itself).
  final VoidCallback? onDone;

  /// Off in tests that don't want the check on open.
  @visibleForTesting
  static bool checkOnOpen = true;

  @override
  State<HostEditor> createState() => _HostEditorState();
}

class _HostEditorState extends State<HostEditor> {
  Host? get _seed => widget.host ?? widget.draft;
  late final _name = TextEditingController(text: _seed?.name ?? '');
  late final _addr = TextEditingController(text: _seed?.address ?? '');
  late final _lan = TextEditingController(text: _seed?.lanAddress ?? '');
  late final _user = TextEditingController(text: _seed?.sshUser ?? '');
  late final _daemonPort = TextEditingController(text: '${_seed?.daemonPort ?? 7433}');
  late final _sshPort = TextEditingController(text: '${_seed?.sshPort ?? 22}');
  late final _key = TextEditingController(text: _seed?.privateKeyPem ?? '');
  late final _pass = TextEditingController(text: _seed?.keyPassphrase ?? '');
  late final _topic = TextEditingController(text: _seed?.ntfyTopic ?? '');
  late final _ntfyServer = TextEditingController(text: _seed?.ntfyServer ?? '');

  /// The name's color in headers; null: picked from the host's id.
  late int? _color = _seed?.color;

  /// Results of host tools (restart, update), shown under them.
  String? _status;

  /// The pinned host key, carried over unless the address or port changes.
  late String? _pinType = widget.host?.hostKeyType;
  late String? _pinFingerprint = widget.host?.hostKeyFingerprint;

  /// A different key seen during the check, offered for trust.
  (String, String)? _changedKey;

  // Health: running, and each row's result (null: not checked yet).
  bool _checking = false;
  _Health? _daemon, _ssh, _hostKey, _watcher;
  bool? _online;
  bool _viaSsh = false;
  String? _version;
  String? _latest;
  WatcherHealth? _health;
  bool _showWatcherDetails = false;

  @override
  void initState() {
    super.initState();
    if (_seed != null && HostEditor.checkOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _check();
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _addr, _lan, _user, _daemonPort, _sshPort, _key, _pass, _topic, _ntfyServer]) {
      c.dispose();
    }
    super.dispose();
  }

  void _done() => widget.onDone != null ? widget.onDone!() : Navigator.pop(context);

  bool get _sameEndpoint =>
      widget.host != null &&
      widget.host!.address == _addr.text.trim() &&
      widget.host!.sshPort == (int.tryParse(_sshPort.text) ?? 22);

  /// Stable for the whole form: Set up saves the host before Save does.
  late final String _id = _seed?.id ?? '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(999)}';

  /// Set up on this host: running, and the last result (ok, message).
  bool _settingUp = false;
  bool _restarting = false;

  /// Update OpenRig: what it's doing ("Checking…", "Updating…"), null when idle.
  String? _updating;
  (bool, String)? _setupResult;

  /// What SSH still needs before the host tools can run, or null when ready.
  String? get _sshNeeds {
    final missing = [
      if (_addr.text.trim().isEmpty) 'the address',
      if (_user.text.trim().isEmpty) 'the SSH user',
      if (_key.text.trim().isEmpty) 'an SSH key',
    ];
    if (missing.isNotEmpty) {
      final list = missing.length == 1
          ? missing.single
          : '${missing.sublist(0, missing.length - 1).join(', ')} and ${missing.last}';
      return 'Needs $list';
    }
    return _keyProblem();
  }

  bool get _sshReady => _sshNeeds == null;

  bool get _busy => _checking || _settingUp || _restarting || _updating != null;

  /// The watcher's launchd agent is installed (from the last check).
  bool get _watcherInstalled => _health?.checks.any((c) => c.label == 'Installed' && c.ok) ?? false;

  Future<void> _setUp() async {
    if (!_sshReady) return;
    // The watcher needs a topic to post to: start notifications with a fresh one.
    if (_topic.text.trim().isEmpty) setState(() => _topic.text = newNtfyTopic());
    final topic = _topic.text.trim();
    if (!validNtfyTopic(topic)) {
      toast(context, 'The ntfy topic may only use letters, digits, - and _');
      return;
    }
    setState(() {
      _settingUp = true;
      _setupResult = null;
    });
    final host = _build();
    try {
      await AppScope.read(context).upsert(host);
      await writeWatcherConfig(host);
      final server = (host.ntfyServer ?? 'https://ntfy.sh').replaceFirst(RegExp(r'/+$'), '');
      await setUpHost(host, await loadWatcherFiles(), server: server);
      if (mounted) setState(() => _setupResult = (true, 'The watcher is running and the hooks are installed.'));
      if (mounted) unawaited(_checkWatcherOnly());
    } catch (e) {
      if (mounted) setState(() => _setupResult = (false, '$e'));
    } finally {
      if (mounted) {
        setState(() {
          _settingUp = false;
          // The connection may have pinned the host key; Save must keep it.
          _pinType = host.hostKeyType ?? _pinType;
          _pinFingerprint = host.hostKeyFingerprint ?? _pinFingerprint;
        });
      }
    }
  }

  Future<void> _restartDaemon() async {
    if (!_sshReady) return;
    final host = _build();
    final ok = await confirmSheet(context,
        title: 'Restart the daemon?',
        body: 'Runs rig daemon stop, then rig daemon start on ${host.name}. '
            'The app loses the daemon for a few seconds.',
        action: 'Restart',
        destructive: false);
    if (!ok || !mounted) return;
    setState(() {
      _restarting = true;
      _status = null;
    });
    try {
      await restartDaemon(host);
      if (mounted) setState(() => _status = 'Restarted the daemon on ${host.name}.');
      if (mounted) await _check(fresh: true); // shows whether the daemon now answers on this address
    } catch (e) {
      if (mounted) setState(() => _status = 'Restart failed: $e');
    } finally {
      if (mounted) setState(() => _restarting = false);
    }
  }

  /// Checks the installed and latest OpenRig, asks, then updates and restarts the daemon.
  Future<void> _updateOpenRig() async {
    if (!_sshReady) return;
    final host = _build();
    setState(() {
      _updating = 'Checking…';
      _status = null;
    });
    try {
      final (installed, latest) = await openRigVersions(host);
      if (!mounted) return;
      setState(() {
        _updating = null;
        _latest = latest;
      });
      if (installed == null) {
        setState(() => _status = 'OpenRig (rig) isn\'t installed on ${host.name}, or isn\'t on the login shell\'s PATH.');
        return;
      }
      final current = latest != null && installed == latest;
      final go = await confirmSheet(context,
          title: current ? 'OpenRig is up to date' : 'Update OpenRig on ${host.name}?',
          body: [
            'Installed $installed · latest ${latest ?? 'unknown (npm didn\'t answer)'}.',
            if (!current)
              'Runs npm install -g @openrig/cli@latest, then restarts the daemon to load it. '
                  'Agents keep running in tmux; the app loses the daemon for a few seconds.',
          ].join('\n\n'),
          action: current ? 'Reinstall anyway' : 'Update',
          cancel: current ? 'Close' : 'Cancel',
          destructive: false);
      if (!go || !mounted) return;
      setState(() => _updating = 'Updating…');
      final now = await updateOpenRig(host);
      if (!mounted) return;
      setState(() => _status = now == installed
          ? 'OpenRig $now reinstalled; the daemon restarted.'
          : 'Updated OpenRig $installed → $now; the daemon restarted.');
      await _check(fresh: true); // shows whether the daemon answers again
    } catch (e) {
      if (mounted) setState(() => _status = 'Update failed: $e');
    } finally {
      if (mounted) setState(() => _updating = null);
    }
  }

  /// The host's color: its name shows in it at the top of its screens. Auto picks one from the host's id; the last
  /// swatch is the host's own colour, chosen in a picker.
  Widget _colorPicker(Tokens k) {
    final auto = hostColor(Host(id: _id, name: '', address: '', sshUser: ''));
    final custom = _color != null && !hostPalette.any((c) => c.toARGB32() == _color);
    // 25 wide (ten fit one line at 390: the row has 252dp) and 44 tall: the circle is 22.
    Widget swatch(Widget? face, Color? fill, bool selected, String spoken, VoidCallback onTap, {bool last = false}) => Semantics(
          button: true,
          selected: selected,
          label: spoken,
          onTap: onTap,
          excludeSemantics: true,
          child: InkResponse(
            onTap: onTap,
            radius: 20,
            child: Container(
              width: 22,
              height: 22,
              margin: EdgeInsets.fromLTRB(0, 11, last ? 0 : 3, 11),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                gradient: fill == null
                    ? const SweepGradient(colors: [
                        Color(0xFFE53935), Color(0xFFFDD835), Color(0xFF43A047), Color(0xFF00ACC1),
                        Color(0xFF1E88E5), Color(0xFF8E24AA), Color(0xFFE53935),
                      ])
                    : null,
                shape: BoxShape.circle,
                border: Border.all(color: selected ? k.ink : Colors.transparent, width: 2),
              ),
              child: face,
            ),
          ),
        );
    Widget pick(Color c, int? value, String spoken) => swatch(
        value == null ? Icon(Icons.auto_awesome, size: 12, color: k.onAccent) : null, c, _color == value, spoken,
        () => setState(() => _color = value));
    Future<void> openPicker() async {
      final chosen = await pickCustomColour(context,
          initial: custom ? Color(_color!) : (_color == null ? auto : Color(_color!)), hostName: _name.text.trim().isEmpty ? 'Host' : _name.text.trim());
      if (chosen != null && mounted) setState(() => _color = chosen.toARGB32());
    }

    return Row(children: [
      Text('Color', style: TextStyle(fontSize: 13, color: k.muted)),
      const SizedBox(width: 8),
      Expanded(
        child: Wrap(children: [
          pick(auto, null, 'Automatic color'),
          for (final (i, c) in hostPalette.indexed) pick(c, c.toARGB32(), 'Color ${i + 1}'),
          swatch(custom ? null : Icon(Icons.add, size: 14, color: k.isDark ? Colors.white : k.ink), custom ? Color(_color!) : null,
              custom, custom ? 'Custom colour, selected' : 'Custom colour', openPicker, last: true),
        ]),
      ),
    ]);
  }

  Host _build() => Host(
        id: _id,
        name: _name.text.trim().isEmpty ? _addr.text.trim().split('.').first : _name.text.trim(),
        address: _addr.text.trim(),
        lanAddress: _lan.text.trim().isEmpty ? null : _lan.text.trim(),
        daemonPort: int.tryParse(_daemonPort.text) ?? 7433,
        sshPort: int.tryParse(_sshPort.text) ?? 22,
        sshUser: _user.text.trim(),
        privateKeyPem: _key.text.trim().isEmpty ? null : '${_key.text.trim()}\n',
        keyPassphrase: _pass.text.isEmpty ? null : _pass.text,
        pinnedFolders: widget.host?.pinnedFolders,
        notifyKinds: {..._kinds},
        ntfyTopic: _topic.text.trim().isEmpty ? null : _topic.text.trim(),
        ntfyServer: _ntfyServer.text.trim().isEmpty ? null : _ntfyServer.text.trim(),
        hostKeyType: _sameEndpoint ? _pinType : null,
        hostKeyFingerprint: _sameEndpoint ? _pinFingerprint : null,
        agentNames: widget.host?.agentNames,
        specFolders: widget.host?.specFolders,
        rigNames: widget.host?.rigNames,
        color: _color,
        enabled: widget.host?.enabled ?? true,
      );

  Future<void> _generateKey() async {
    final ok = await confirmSheet(context,
        title: _key.text.trim().isEmpty ? 'Generate a new key?' : 'Replace the saved key?',
        body: 'Makes an ed25519 key on this device. It only works once its public half is in the host\'s '
            '~/.ssh/authorized_keys; copy it from here after.',
        action: _key.text.trim().isEmpty ? 'Generate' : 'Replace',
        destructive: false);
    if (!ok) return;
    final k = generateEd25519(
        comment: 'pocketrig@${_name.text.trim().isEmpty ? 'phone' : _name.text.trim().replaceAll(' ', '-')}');
    setState(() {
      _key.text = k.privatePem;
      _pass.clear();
    });
  }

  String? _keyProblem() {
    if (_key.text.trim().isEmpty) return null;
    try {
      SSHKeyPair.fromPem(_key.text.trim(), _pass.text.isEmpty ? null : _pass.text);
      return null;
    } catch (e) {
      return 'Key not readable: $e';
    }
  }

  /// Health: the daemon, SSH, the host key and the watcher. [fresh] (Test
  /// again) tries the direct route afresh and connects without the pool, to
  /// show the host key it presents.
  Future<void> _check({bool fresh = false}) async {
    if (_addr.text.trim().isEmpty || _checking) return;
    setState(() {
      _checking = true;
      _daemon = (_Verdict.unknown, 'checking…');
    });
    final host = _build();
    if (fresh) DaemonRoute.of(host).resetToDirect();
    final probe = OpenRigClient.create(host);
    var daemon = false;
    String? version;
    try {
      daemon = await probe.healthy();
      version = daemon ? await probe.version() : null;
    } finally {
      probe.close();
    }
    final viaSsh = daemon && DaemonRoute.of(host).viaSsh;
    if (daemon) hostLastSeen[host.id] = DateTime.now();
    if (!mounted) return;
    setState(() {
      _online = daemon;
      _viaSsh = viaSsh;
      _version = version ?? _version;
      _daemon = !daemon
          ? (_Verdict.bad, 'not reachable at ${host.address}:${host.daemonPort}')
          : viaSsh
              ? (_Verdict.bad, sshOverLan(host) ? 'via SSH · Tailscale didn\'t answer' : 'via SSH · not on the tailnet')
              : (_Verdict.ok, 'direct · :${host.daemonPort}');
    });

    final needs = _sshNeeds;
    if (needs != null) {
      setState(() {
        _ssh = (_keyProblem() != null ? _Verdict.bad : _Verdict.unknown, needs);
        _hostKey = (_Verdict.unknown, '—');
        _watcher = (_Verdict.unknown, '—');
        _checking = false;
      });
      return;
    }

    var sshOk = false;
    if (fresh) {
      String? fp;
      try {
        final client = await sshConnect(host, pin: false, onHostKey: (type, f) => fp = '$type $f');
        client.close();
        sshOk = true;
        _ssh = (_Verdict.ok, '${host.sshUser}@${host.address}${sshOverLan(host) ? ' · over the local network' : ''}');
        if (host.hostKeyFingerprint == null && fp != null) {
          // First contact: pin it when the host is saved.
          final parts = fp!.split(' ');
          _pinType = parts.first;
          _pinFingerprint = parts.last;
          _hostKey = (_Verdict.ok, 'will be pinned on save');
        } else {
          _hostKey = (_Verdict.ok, 'matches pinned');
        }
      } on HostKeyChangedException catch (e) {
        _keyChanged(e);
      } catch (e) {
        _ssh = (_Verdict.bad, '$e');
      }
      if (mounted) setState(() {});
      if (!sshOk) {
        if (mounted) {
          setState(() {
            _watcher = (_Verdict.unknown, '—');
            _checking = false;
          });
        }
        return;
      }
    }
    await _checkWatcherOnly(host: host, sshKnown: sshOk);
    if (mounted) setState(() => _checking = false);
  }

  void _keyChanged(HostKeyChangedException e) {
    _changedKey = (e.seenType, e.seen);
    _ssh = (_Verdict.bad, 'refused: the host key changed');
    _hostKey = (_Verdict.bad, 'changed · see below');
    _watcher = (_Verdict.unknown, '—');
  }

  /// The watcher check over SSH. It also proves SSH and the pinned key when
  /// [sshKnown] is false.
  Future<void> _checkWatcherOnly({Host? host, bool sshKnown = false}) async {
    host ??= _build();
    if (_sshNeeds != null) return;
    setState(() => _watcher = (_Verdict.unknown, 'checking…'));
    try {
      final h = await checkWatcher(host, await loadWatcherFiles());
      if (!mounted) return;
      setState(() {
        _health = h;
        if (!sshKnown) {
          _ssh = (_Verdict.ok, '${host!.sshUser}@${host.address}${sshOverLan(host) ? ' · over the local network' : ''}');
          _pinType = host.hostKeyType ?? _pinType;
          _pinFingerprint = host.hostKeyFingerprint ?? _pinFingerprint;
          _hostKey = (_Verdict.ok, widget.host?.hostKeyFingerprint == null ? 'pinned on first connect' : 'matches pinned');
        }
        final bad = h.checks.where((c) => !c.ok).firstOrNull;
        _watcher = bad == null
            ? (_Verdict.ok, (_topic.text.trim().isEmpty ? 'running · notifications off' : 'running · hooks in place'))
            : (_Verdict.bad, '${bad.label}: ${bad.detail}');
      });
    } on HostKeyChangedException catch (e) {
      if (mounted) setState(() => _keyChanged(e));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (sshKnown) {
          _watcher = (_Verdict.bad, '$e');
        } else {
          _ssh = (_Verdict.bad, '$e');
          _hostKey = (_Verdict.unknown, '—');
          _watcher = (_Verdict.unknown, '—');
        }
      });
    }
  }

  Future<void> _save() async {
    final needs = [
      if (_addr.text.trim().isEmpty) 'the address',
      if (_user.text.trim().isEmpty) 'the SSH user',
    ];
    if (needs.isNotEmpty) {
      toast(context, 'Add ${needs.join(' and ')} to save');
      return;
    }
    final problem = _keyProblem();
    if (problem != null) {
      toast(context, problem);
      return;
    }
    if (_topic.text.trim().isNotEmpty && !validNtfyTopic(_topic.text.trim())) {
      toast(context, 'The ntfy topic may only use letters, digits, - and _');
      return;
    }
    final store = AppScope.read(context);
    final host = _build();
    await store.upsert(host);
    await store.select(host.id);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final k = Tokens.of(context);
    _done();
    // Tell the host's watcher how this host is named, how the phone reaches
    // it, and which kinds to notify about. Best effort: the host still saves.
    if (host.ntfyTopic != null && host.privateKeyPem != null) {
      try {
        await writeWatcherConfig(host);
      } catch (e) {
        toastOn(messenger, k, 'Saved. Couldn\'t update the watcher on ${host.name}: $e');
      }
    }
  }

  /// Kinds ticked in the form ([NotifyKind] ids).
  late final Set<String> _kinds = {..._seed?.notifyKinds ?? NotifyKind.defaults};

  late bool _showKey = (_seed?.privateKeyPem ?? '').isEmpty;
  bool _editTopic = false;

  /// The header's one line: what the last check found.
  (Status, String) get _headline {
    if (_online == null) {
      return _checking
          ? (Status.idle, 'Checking…')
          : (Status.idle, widget.host == null ? 'Not saved yet · not checked' : 'Not checked yet');
    }
    if (_online == false) return (Status.failed, 'Offline · the daemon doesn\'t answer');
    if (_viaSsh) return (Status.degraded, 'Online via SSH · daemon isn\'t on the tailnet');
    final live = widget.host != null && AppScope.clientFor(widget.host!).live.connected.value;
    return (
      Status.working,
      ['Online', 'tailnet', if (live) 'live events', if (_version != null) 'OpenRig $_version'].join(' · ')
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final monoStyle = mono(context, size: 13, color: k.ink);
    Widget field(String label, TextEditingController c,
            {String? hint,
            bool isMono = false,
            TextInputType? type,
            bool obscure = false,
            ValueChanged<String>? onChanged}) =>
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(label, style: TextStyle(fontSize: 12, color: k.muted)),
          const SizedBox(height: 6),
          TextField(
            controller: c,
            autocorrect: false,
            enableSuggestions: !isMono,
            keyboardType: type,
            obscureText: obscure,
            onChanged: onChanged ?? (_) => setState(() {}),
            style: isMono ? monoStyle : const TextStyle(fontSize: 15),
            // One height for mono and sans fields, so SSH user and the port beside it match.
            decoration: InputDecoration(
                hintText: hint,
                constraints: const BoxConstraints.tightFor(height: 48),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13)),
          ),
        ]);
    Widget card(List<Widget> children) => Panel(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        );
    Widget note(String text, {Color? color}) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(text, style: TextStyle(fontSize: 12, color: color ?? k.muted, height: 1.4)),
        );
    const gap = SizedBox(height: 18);
    final summary =
        _key.text.trim().isEmpty ? null : keySummary(_key.text, passphrase: _pass.text.isEmpty ? null : _pass.text);
    final pub = _key.text.trim().isEmpty
        ? null
        : publicKeyFromPem(_key.text, passphrase: _pass.text.isEmpty ? null : _pass.text);
    final needs = _sshNeeds;
    final (headStatus, headLine) = _headline;
    final title = widget.host?.name ?? (_name.text.trim().isNotEmpty ? _name.text.trim() : 'Add host');
    return Scaffold(
      body: Column(children: [
        PageHeader(
          overline: 'Settings',
          title: title,
          subtitle: Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                StatusShape(headStatus, size: 8, semantics: false),
                const SizedBox(width: 6),
                Flexible(child: Text(headLine, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.muted))),
              ]),
            ),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: PillButton('Save', filled: true, onPressed: _save),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              // ── Enabled ── (This Mac stays on, and a host not saved yet is on.)
              if (widget.host != null && !(isDesktop && widget.host!.isLocal)) ...[
                BorderedList(children: [
                  ValueListenableBuilder<Set<String>>(
                    valueListenable: busyKeys,
                    builder: (context, busy, _) => SwitchRow(
                      'Enabled',
                      subtitle: 'Applies now, no need to Save. Off hides the host and stops its notifications; everything saved stays.',
                      value: widget.host!.enabled,
                      // Disabled while its watcher write runs, so a quick off/on can't land out of order.
                      onChanged: busy.contains('host:${widget.host!.id}')
                          ? null
                          : (on) async {
                              await setHostEnabled(context, widget.host!, on);
                              if (mounted) setState(() {});
                            },
                    ),
                  ),
                ]),
                gap,
              ],
              // ── Health ──
              SectionLabel(
                'Health',
                trailing: TextButton(
                  onPressed: _addr.text.trim().isEmpty || _busy ? null : () => _check(fresh: true),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6)).merge(compactAction),
                  child: Text(_checking ? 'Testing…' : (_online == null ? 'Test' : 'Test again')),
                ),
              ),
              BorderedList(children: [
                _HealthRow('Daemon', _daemon),
                _HealthRow('SSH', _ssh),
                _HealthRow('Host key', _hostKey),
                _HealthRow('Watcher & hooks', _watcher,
                    onTap: _health == null ? null : () => setState(() => _showWatcherDetails = !_showWatcherDetails)),
              ]),
              if (_addr.text.trim().isEmpty) note('Add the address to test this host.'),
              if (_health != null && _showWatcherDetails) ...[
                const SizedBox(height: 8),
                _WatcherHealthView(_health!),
              ],
              if (_changedKey != null) _changedKeyCard(k),
              gap,

              // ── Connection ──
              const SectionLabel('Connection'),
              card([
                field('Name', _name, hint: 'homelab'),
                const SizedBox(height: 10),
                _colorPicker(k),
                const SizedBox(height: 14),
                field('Tailscale name or 100.x IP', _addr, hint: 'homelab.tail1234.ts.net', isMono: true, type: TextInputType.url),
                const SizedBox(height: 14),
                field('Local network IP · fallback when Tailscale stalls', _lan,
                    hint: '192.168.1.20', isMono: true, type: TextInputType.url),
                const SizedBox(height: 14),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 2, child: field('SSH user', _user)),
                  const SizedBox(width: 10),
                  Expanded(child: field('SSH port', _sshPort, isMono: true, type: TextInputType.number)),
                  const SizedBox(width: 10),
                  Expanded(child: field('Daemon port', _daemonPort, isMono: true, type: TextInputType.number)),
                ]),
              ]),
              gap,

              // ── SSH key ──
              const SectionLabel('SSH key'),
              card([
                Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(summary ?? (_key.text.trim().isEmpty ? 'No key yet' : 'Key not readable'),
                          style: mono(context, size: 12, color: summary == null ? k.muted : k.ink)),
                      if (summary != null) Text('Stored in the phone\'s keychain', style: TextStyle(fontSize: 12, color: k.muted)),
                    ]),
                  ),
                  if (pub != null)
                    OutlinedButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: pub));
                        toast(context, 'Public key copied — add it to ~/.ssh/authorized_keys');
                      },
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)).merge(compactAction),
                      child: const Text('Copy public key'),
                    ),
                ]),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  OutlinedButton(onPressed: _generateKey, child: const Text('Generate new…')),
                  OutlinedButton(
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (mounted && data?.text != null) setState(() => _key.text = data!.text!);
                    },
                    child: const Text('Paste private key'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _showKey = !_showKey),
                    child: Text(_showKey ? 'Hide key' : 'Edit key'),
                  ),
                ]),
                if (_showKey) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _key,
                    minLines: 3,
                    maxLines: 8,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: mono(context, size: 11, color: k.ink),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(hintText: '-----BEGIN OPENSSH PRIVATE KEY-----'),
                  ),
                  const SizedBox(height: 10),
                  field('Key passphrase (if any)', _pass, obscure: true),
                ],
                if (_keyProblem() case final p?) note(p, color: k.removed),
                if (pub != null && _key.text.trim().isNotEmpty)
                  _PublicKey(pem: _key.text, passphrase: _pass.text.isEmpty ? null : _pass.text),
                if (_pinFingerprint != null && _sameEndpoint)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('Pinned host key: $_pinType $_pinFingerprint', style: mono(context)),
                  ),
              ]),
              gap,

              // ── Notify me about ──
              const SectionLabel('Notify me about'),
              BorderedList(children: [
                for (final kind in NotifyKind.values)
                  SwitchRow(
                    kind.label,
                    subtitle: kind.hint,
                    value: _topic.text.trim().isNotEmpty && _kinds.contains(kind.id),
                    onChanged: (v) => setState(() {
                      v ? _kinds.add(kind.id) : _kinds.remove(kind.id);
                      // Turning a kind on with notifications off starts them with a fresh topic.
                      if (v && _topic.text.trim().isEmpty) _topic.text = newNtfyTopic();
                    }),
                  ),
                _TopicRow(
                  topic: _topic,
                  server: _ntfyServer,
                  editing: _editTopic,
                  onEdit: () => setState(() => _editTopic = !_editTopic),
                  onChanged: () => setState(() {}),
                  onOff: () => setState(() {
                    _topic.clear();
                    _editTopic = false;
                  }),
                  onOn: () => setState(() => _topic.text = newNtfyTopic()),
                ),
              ]),
              note('From a notification you can allow once or deny. Always-allow stays in the app.'),
              if (_topic.text.trim().isNotEmpty && _topic.text.trim() != (widget.host?.ntfyTopic ?? ''))
                note('The watcher on the host needs the new topic: Save, then Reinstall watcher & hooks.'),
              gap,

              // ── Host tools ──
              const SectionLabel('Host tools'),
              BorderedList(children: [
                _ToolRow(
                  'Update OpenRig',
                  value: _updating ??
                      (_version != null && _latest != null && _latest != _version
                          ? '$_version → $_latest'
                          : (_version ?? (_latest != null ? 'latest $_latest' : null))),
                  needs: needs,
                  busy: _updating != null,
                  onTap: _busy ? null : _updateOpenRig,
                ),
                _ToolRow('Restart daemon…', needs: needs, busy: _restarting, onTap: _busy ? null : _restartDaemon),
                _ToolRow(
                  _watcherInstalled ? 'Reinstall watcher & hooks' : 'Set up on this host',
                  value: _settingUp ? 'Setting up…' : null,
                  needs: needs,
                  busy: _settingUp,
                  onTap: _busy ? null : _setUp,
                ),
                _ToolRow(
                  'Machines this daemon can reach',
                  needs: needs,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => RegistryHostsScreen(host: _build()))),
                ),
                _ToolRow(
                  'SSH log',
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => SshLogScreen(hostName: _build().name))),
                ),
              ]),
              if (_setupResult != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: SelectableText('${_setupResult!.$1 ? '✓' : '✕'} ${_setupResult!.$2}',
                        style: TextStyle(fontSize: 13, color: _setupResult!.$1 ? k.added : k.removed)),
                  ),
                ),
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Semantics(liveRegion: true, child: SelectableText(_status!, style: const TextStyle(fontSize: 13))),
                ),
              if (widget.host != null) ...[
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: _remove,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: k.removed,
                    side: BorderSide(color: k.removed)).merge(sheetAction),
                  child: const Text('Remove host from this device…'),
                ),
              ],
            ],
          ),
        ),
      ]),
    );
  }

  Future<void> _remove() async {
    final host = widget.host!;
    final ok = await confirmSheet(context,
        title: 'Remove ${host.name}?',
        body: 'Its saved key and settings leave this device. Nothing changes on the host.',
        action: 'Remove');
    if (!ok || !mounted) return;
    await AppScope.read(context).remove(host.id);
    if (mounted) _done();
  }

  Widget _changedKeyCard(Tokens k) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Panel(
          borderColor: k.removed,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('The host presented a different SSH key', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('Pinned: $_pinFingerprint\nNow:    ${_changedKey!.$2}', style: mono(context, size: 12, color: k.ink)),
          const SizedBox(height: 6),
          const Text(
              'Expected after reinstalling the OS or regenerating host keys. Otherwise someone may be '
              'impersonating the host. Compare with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on it.',
              style: TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: k.removed, side: BorderSide(color: k.removed)),
            onPressed: () => setState(() {
              _pinType = _changedKey!.$1;
              _pinFingerprint = _changedKey!.$2;
              _changedKey = null;
              _hostKey = (_Verdict.ok, 'new key trusted on save');
              _status = 'New key will be trusted when you save.';
            }),
            child: const Text('Trust the new key'),
          ),
        ]),
        ),
      );
}
