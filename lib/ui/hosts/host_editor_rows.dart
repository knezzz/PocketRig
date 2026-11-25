part of 'host_editor.dart';

/// One Health row: its check mark (passed, a problem, or not known), the label and the detail.
class _HealthRow extends StatelessWidget {
  const _HealthRow(this.label, this.result, {this.onTap});
  final String label;
  final _Health? result;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (verdict, detail) = result ?? (_Verdict.unknown, 'not checked');
    return CheckRow(
      switch (verdict) {
        _Verdict.ok => CheckState.ok,
        _Verdict.bad => CheckState.bad,
        _Verdict.unknown => CheckState.off,
      },
      label,
      detail: detail,
      layout: CheckLayout.tile,
      onTap: onTap,
    );
  }
}

/// A Host tools row. When SSH isn't ready it says what's missing instead of
/// doing nothing.
class _ToolRow extends StatelessWidget {
  const _ToolRow(this.label, {this.value, this.needs, this.busy = false, this.onTap});
  final String label;
  final String? value;

  /// Why it can't run yet; null when it can.
  final String? needs;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final enabled = needs == null && onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: [label, if (value != null) value!, if (needs != null) needs!].join(', '),
      excludeSemantics: true,
      onTap: enabled ? onTap : null,
      child: RowTile(
        minHeight: 52,
        // The › always ends tileArrowInset from the edge, enabled or not, so the column doesn't step while a tool runs.
        padding: const EdgeInsets.fromLTRB(14, 8, tileArrowInset, 8),
        onTap: enabled ? onTap : null,
        arrow: enabled,
        // Not ready: the row says why and keeps its chevron, but takes no tap.
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (busy)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          if (value != null) Text(value!, style: mono(context, size: 11)),
          if (!enabled) ...[const SizedBox(width: 8), const Chevron()],
        ]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 15, color: needs == null ? k.ink : k.muted)),
          if (needs != null) Text(needs!, style: TextStyle(fontSize: 12, color: k.muted)),
        ]),
      ),
    );
  }
}

/// The ntfy topic the host's watcher posts to, Subscribe in ntfy, and (on
/// Edit) the topic and server fields.
class _TopicRow extends StatelessWidget {
  const _TopicRow({
    required this.topic,
    required this.server,
    required this.editing,
    required this.onEdit,
    required this.onChanged,
    required this.onOff,
    required this.onOn,
  });
  final TextEditingController topic;
  final TextEditingController server;
  final bool editing;
  final VoidCallback onEdit;
  final VoidCallback onChanged;
  final VoidCallback onOff;
  final VoidCallback onOn;

  String get _server =>
      (server.text.trim().isEmpty ? 'https://ntfy.sh' : server.text.trim()).replaceFirst(RegExp(r'/+$'), '');

  Future<void> _subscribe() async {
    final t = topic.text.trim();
    final base = Uri.parse(_server);
    // The ntfy app handles ntfy://<server>/<topic>; the web page is the fallback.
    final app = Uri.parse('ntfy://${base.host}${base.hasPort ? ':${base.port}' : ''}/$t');
    if (!await launchUrl(app, mode: LaunchMode.externalApplication)) {
      await launchUrl(Uri.parse('$_server/$t'), mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final t = topic.text.trim();
    if (t.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(children: [
          Expanded(child: Text('Notifications are off', style: TextStyle(fontSize: 14, color: k.muted))),
          OutlinedButton(onPressed: onOn, child: const Text('Turn on')),
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The whole row edits the topic; Subscribe is its own button.
      RowTile(
        minHeight: 0,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
        onTap: onEdit,
        trailing: OutlinedButton(onPressed: _subscribe, child: const Text('Subscribe in ntfy')),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('ntfy topic', style: TextStyle(fontSize: 12, color: k.muted)),
          Text(t, style: mono(context, size: 12, color: k.ink)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (editing) ...[
          const SizedBox(height: 10),
          Text('The topic works like a password: keep it private.', style: TextStyle(fontSize: 12, color: k.muted)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: topic,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: fontMono),
                onChanged: (_) => onChanged(),
                decoration: const InputDecoration(labelText: 'ntfy topic'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(
              tooltip: 'Generate a topic',
              onPressed: () {
                topic.text = newNtfyTopic();
                onChanged();
              },
              icon: const Icon(Icons.casino_outlined),
            ),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: server,
            autocorrect: false,
            keyboardType: TextInputType.url,
            style: const TextStyle(fontFamily: fontMono),
            onChanged: (_) => onChanged(),
            decoration: const InputDecoration(labelText: 'ntfy server (optional)', hintText: 'https://ntfy.sh'),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onOff,
              style: TextButton.styleFrom(foregroundColor: k.removed),
              child: const Text('Turn notifications off'),
            ),
          ),
        ] else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: onEdit, child: const Text('Edit topic or server')),
          ),
        ]),
      ),
    ]);
  }
}

/// The watcher check's results: one row per check, then the log's last lines.
class _WatcherHealthView extends StatelessWidget {
  const _WatcherHealthView(this.health);
  final WatcherHealth health;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final t = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      label: health.ok ? 'Watcher healthy' : 'Watcher has problems',
      child: Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final c in health.checks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.ok ? '✓' : '✕', style: TextStyle(fontWeight: FontWeight.w700, color: c.ok ? k.added : k.removed)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: '${c.label}  ', style: const TextStyle(fontWeight: FontWeight.w600)),
                      TextSpan(text: c.detail, style: TextStyle(color: c.ok ? k.muted : k.ink)),
                    ]),
                    style: const TextStyle(fontSize: 13, height: 1.35),
                  ),
                ),
              ]),
            ),
          if (health.log.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('pocketrig-watcher.log', style: t.bodySmall),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: k.fill, borderRadius: BorderRadius.circular(kRadius)),
              child: SelectableText(health.log.join('\n'), style: mono(context, size: 11, color: k.ink)),
            ),
          ],
        ]),
      ),
    );
  }
}

/// The public half of the key in the form, ready for authorized_keys.
class _PublicKey extends StatelessWidget {
  const _PublicKey({required this.pem, this.passphrase});
  final String pem;
  final String? passphrase;

  @override
  Widget build(BuildContext context) {
    if (pem.trim().isEmpty) return const SizedBox.shrink();
    final line = publicKeyFromPem(pem, passphrase: passphrase);
    if (line == null) return const SizedBox.shrink();
    final k = Tokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Public key: add this line to ~/.ssh/authorized_keys on the host', style: TextStyle(fontSize: 12, color: k.muted)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          decoration: BoxDecoration(color: k.fill, borderRadius: BorderRadius.circular(kRadius)),
          child: Row(children: [
            Expanded(child: SelectableText(line, style: mono(context, size: 11, color: k.ink))),
            IconButton(
              tooltip: 'Copy public key',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: line));
                toast(context, 'Public key copied');
              },
              icon: const Icon(Icons.copy, size: 18),
            ),
          ]),
        ),
      ]),
    );
  }
}
