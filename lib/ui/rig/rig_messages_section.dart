import 'package:flutter/material.dart';

import '../../data/rig_messages.dart';
import '../../main.dart';
import '../../models.dart';
import '../common.dart';
import '../kit.dart';
import '../theme.dart';

/// The rig's `rig send` messages, newest first: read from its Claude seats' transcripts (OpenRig keeps no
/// record of sends), [step] at a time.
class RigMessagesSection extends StatefulWidget {
  const RigMessagesSection({super.key, required this.rig, this.active = true});
  final Rig rig;

  /// Loads only while shown: each load tails every Claude seat's transcript over SSH.
  final bool active;
  static const step = 50;
  @override
  State<RigMessagesSection> createState() => _RigMessagesSectionState();
}

class _RigMessagesSectionState extends State<RigMessagesSection> with Polling {
  List<RigMessage>? _messages;
  String? _error;
  int _limit = RigMessagesSection.step;

  // Each load reads every seat's transcript tail over SSH: slowly, and on demand.
  @override
  Duration get every => const Duration(minutes: 2);
  @override
  Duration get slowEvery => const Duration(minutes: 5);
  @override
  bool wants(RigEvent e) => false;

  /// The rig's Claude seats, from its last load; null until then.
  List<Seat>? _seats;

  @override
  Future<void> load() async {
    if (!widget.active) return;
    final host = AppScope.read(context).active;
    final api = AppScope.clientOf(context);
    if (host == null || api == null) return;
    try {
      final seats = [
        for (final s in await api.seats(widget.rig.id))
          if (s.isClaude) s
      ];
      final found = await loadRigMessages(host, seats, limit: _limit);
      if (!mounted) return;
      setState(() {
        _seats = seats;
        _messages = found;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void didUpdateWidget(RigMessagesSection old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) load();
  }

  void _open(RigMessage m) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_route(m), style: Theme.of(context).textTheme.titleMedium),
                if (m.at case final at?) Text(agoPhrase(at), style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                SelectableText(m.body),
              ]),
            ),
          ),
        ),
      );

  /// "dev-dev2 › product-lead": the rig's own seats without the '@rig'.
  String _route(RigMessage m) {
    String short(String s) =>
        s.endsWith('@${widget.rig.name}') ? s.substring(0, s.length - widget.rig.name.length - 1) : s;
    return '${short(m.from)} › ${m.to.map(short).join(', ')}';
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final messages = _messages;
    final empty = (_seats ?? const []).isEmpty
        ? 'No messages to show: ${widget.rig.name} has no Claude seat, and only Claude seats keep a transcript '
            'the app can read.'
        : 'No messages between seats yet. Messages seats send each other with rig send show here.';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(messages == null || messages.isEmpty ? 'Messages' : 'Messages · ${messages.length}'),
      if (_error != null)
        ErrorBanner(_error!, margin: const EdgeInsets.only(bottom: 12))
      else if (messages == null)
        // No spinner while hidden: nothing loads then, and it would run forever.
        widget.active
            ? const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
            : const SizedBox(height: 48)
      else if (messages.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
          child: Text(empty, style: TextStyle(fontSize: 13, color: k.muted)),
        )
      else ...[
        BorderedList(children: [
          for (final m in messages)
            RowTile(
              onTap: () => _open(m),
              openLabel: '${_route(m)}, ${m.at == null ? '' : agoPhrase(m.at!)}: ${m.body}',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(_route(m),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono(context, size: 12, color: k.ink).copyWith(fontWeight: FontWeight.w600)),
                  ),
                  if (m.at case final at?) Text(agoPhrase(at), style: TextStyle(fontSize: 12, color: k.faint)),
                ]),
                const SizedBox(height: 4),
                Text(m.body,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
        ]),
        if (messages.length >= _limit)
          TextButton(
            onPressed: () {
              setState(() => _limit += RigMessagesSection.step);
              load();
            },
            child: const Text('Show more'),
          ),
      ],
      const SizedBox(height: 16),
    ]);
  }
}
