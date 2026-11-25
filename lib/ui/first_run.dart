import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/deep_link.dart' show newNtfyTopic;
import '../models.dart';
import '../ssh/keygen.dart';
import 'common.dart';
import 'kit.dart';
import 'switch_row.dart';
import 'theme.dart';

/// Settings with no host yet: four steps to the first one (Tailscale on this
/// phone, the computer's name, an SSH key, notifications), then the host
/// editor takes over with what was filled in, to test and save it.
class FirstRunSetup extends StatefulWidget {
  const FirstRunSetup({super.key, required this.onContinue, required this.onManual});

  /// The last step's Continue: a host to finish in the editor (not saved yet).
  final ValueChanged<Host> onContinue;

  /// Skip the steps and fill in the editor by hand.
  final VoidCallback onManual;

  @override
  State<FirstRunSetup> createState() => _FirstRunSetupState();
}

class _FirstRunSetupState extends State<FirstRunSetup> {
  int _step = 0;
  final _addr = TextEditingController();
  final _user = TextEditingController();
  GeneratedKey? _key;
  bool _notify = true;

  @override
  void dispose() {
    _addr.dispose();
    _user.dispose();
    super.dispose();
  }

  /// Why Continue can't go on from this step yet, or null.
  String? get _blocked => switch (_step) {
        1 when _addr.text.trim().isEmpty => 'Type the computer\'s name to go on',
        2 when _user.text.trim().isEmpty => 'Type your user name on the computer to go on',
        2 when _key == null => 'Make a key to go on',
        _ => null,
      };

  void _continue() {
    if (_blocked != null) return;
    if (_step < 3) {
      setState(() => _step++);
      return;
    }
    final addr = _addr.text.trim();
    widget.onContinue(Host(
      id: '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(999)}',
      name: addr.split('.').first,
      address: addr,
      sshUser: _user.text.trim(),
      privateKeyPem: _key?.privatePem,
      ntfyTopic: _notify ? newNtfyTopic() : null,
    ));
  }

  void _makeKey() => setState(() => _key = generateEd25519(comment: 'pocketrig@${_addr.text.trim().split('.').first}'));

  void _howToDaemon() => confirmSheet(
        context,
        title: 'Start the OpenRig daemon',
        body: 'On your computer, in a terminal:\n\n'
            'npm install -g @openrig/cli\n'
            'rig daemon start\n\n'
            'Start it after Tailscale is up, so it listens on the tailnet too. '
            'PocketRig also needs Remote Login (SSH) turned on: System Settings → General → Sharing.',
        cancel: 'Close',
      );

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final t = Theme.of(context).textTheme;
    final blocked = _blocked;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Connect your first host', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text(
        'PocketRig talks to the OpenRig daemon on your computer over Tailscale, with SSH as a fallback. '
        'Four steps, about five minutes.',
        style: TextStyle(color: k.muted, height: 1.45),
      ),
      const SizedBox(height: 18),
      _Step(
        n: 1,
        state: _state(0),
        title: 'Tailscale on this device',
        hint: _step > 0 ? 'On' : 'Install Tailscale, sign in, and turn it on. Your computer must be on the same tailnet.',
        child: _step == 0
            ? Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(onPressed: () => setState(() => _step = 1), child: const Text('It\'s on')),
              )
            : null,
      ),
      _Step(
        n: 2,
        state: _state(1),
        title: 'Your computer\'s name',
        hint: _step > 1 ? _addr.text.trim() : 'The full MagicDNS name or a 100.x IP',
        child: _step == 1
            ? TextField(
                controller: _addr,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                style: mono(context, size: 13, color: k.ink),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _continue(),
                decoration: const InputDecoration(hintText: 'homelab.tail1234.ts.net', labelText: 'Host address'),
              )
            : null,
      ),
      _Step(
        n: 3,
        state: _state(2),
        title: 'SSH key',
        hint: _step > 2 ? '${_user.text.trim()} · ${_key == null ? '' : 'ed25519'}' : 'We make one; you add a line to authorized_keys',
        child: _step == 2 ? _keyStep(context, k) : null,
      ),
      _Step(
        n: 4,
        state: _state(3),
        title: 'Notifications',
        hint: 'Optional · the watcher pings you when a seat needs you',
        last: true,
        child: _step == 3
            ? SwitchRow(
                'Notify me',
                subtitle: 'You subscribe in the ntfy app after saving.',
                inset: false,
                value: _notify,
                onChanged: (v) => setState(() => _notify = v),
              )
            : null,
      ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: blocked == null ? _continue : null,
        style: sheetAction,
        child: Text(_step == 3 ? 'Continue to test and save' : 'Continue'),
      ),
      if (blocked != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(blocked, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: k.muted)),
        ),
      const SizedBox(height: 4),
      TextButton(onPressed: _howToDaemon, child: const Text('How to start the OpenRig daemon')),
      TextButton(onPressed: widget.onManual, child: const Text('Add host by hand')),
    ]);
  }

  _StepState _state(int i) => i < _step ? _StepState.done : (i == _step ? _StepState.current : _StepState.later);

  Widget _keyStep(BuildContext context, Tokens k) {
    final key = _key;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _user,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(labelText: 'Your user on the computer', hintText: 'me'),
      ),
      const SizedBox(height: 10),
      if (key == null)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(onPressed: _makeKey, icon: const Icon(Icons.key, size: 16), label: const Text('Make a key')),
        )
      else ...[
        Text('Add this line to ~/.ssh/authorized_keys on the computer:', style: TextStyle(fontSize: 12, color: k.muted)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
          decoration: BoxDecoration(color: k.fill, borderRadius: BorderRadius.circular(kRadius)),
          child: Row(children: [
            Expanded(child: Text(key.publicLine, maxLines: 2, overflow: TextOverflow.ellipsis, style: mono(context, size: 11, color: k.ink))),
            IconButton(
              tooltip: 'Copy public key',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: key.publicLine));
                toast(context, 'Public key copied');
              },
            ),
          ]),
        ),
      ],
    ]);
  }
}

enum _StepState { done, current, later }

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.state, required this.title, required this.hint, this.child, this.last = false});
  final int n;
  final _StepState state;
  final String title;
  final String hint;
  final Widget? child;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final done = state == _StepState.done;
    final current = state == _StepState.current;
    final badge = Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? k.added.withValues(alpha: .14) : (current ? k.ink : Colors.transparent),
        border: Border.all(color: done ? k.added : (current ? k.ink : k.border), width: 1.5),
      ),
      child: Text(done ? '✓' : '$n',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: done ? k.added : (current ? k.onInk : k.muted))),
    );
    return Semantics(
      container: true,
      label: 'Step $n of 4${done ? ', done' : current ? ', current' : ''}',
      child: Padding(
        padding: EdgeInsets.only(bottom: last ? 8 : 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          badge,
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SizedBox(height: 3),
              Text(title,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: state == _StepState.later ? k.muted : k.ink)),
              const SizedBox(height: 2),
              Text(hint, style: TextStyle(fontSize: 12, color: done ? k.added : k.muted, height: 1.4)),
              if (child != null) ...[const SizedBox(height: 10), child!],
            ]),
          ),
        ]),
      ),
    );
  }
}
