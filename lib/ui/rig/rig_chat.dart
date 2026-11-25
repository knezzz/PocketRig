import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models.dart';
import '../common.dart';
import '../kit.dart';
import '../theme.dart';

String _who(String? session) => session?.split('@').first ?? 'someone';

/// A handoff as a chat message: "dev-ios → dev-qa · 2h", the summary, and
/// the item's state. The Work screen's Handoffs tab lists them.
class RigChatMessage extends StatelessWidget {
  const RigChatMessage({super.key, required this.item, required this.onTap, this.withRigs = false});
  final QueueItem item;
  final VoidCallback onTap;

  /// Names seats as `member@rig`, for messages from many rigs.
  final bool withRigs;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    String name(String? session) => withRigs ? (session ?? 'someone') : _who(session);
    // An unknown sender is not named: just where it went.
    final from = item.sourceSession == null ? null : name(item.sourceSession);
    final age = item.created ?? item.updated;
    final text = item.body.isNotEmpty ? item.body : item.summary;
    return Semantics(
      button: true,
      label: '${from == null ? 'To' : '$from to'} ${name(item.destinationSession)}, ${item.state}: ${item.summary}',
      onTap: onTap,
      excludeSemantics: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text.rich(
            TextSpan(children: [
              if (from != null) ...[
                TextSpan(text: from, style: TextStyle(color: k.ink, fontWeight: FontWeight.w600)),
                const TextSpan(text: '  →  '),
              ],
              TextSpan(
                  text: name(item.destinationSession), style: TextStyle(color: k.ink, fontWeight: FontWeight.w600)),
              if (age != null) TextSpan(text: '  ·  ${ago(age)}'),
            ]),
            style: TextStyle(fontSize: 12, color: k.muted),
          ),
        ),
        Panel(
          onTap: onTap,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (item.summary.isNotEmpty && item.body.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child:
                    Text(item.summary, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.35)),
              ),
            Text(text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, height: 1.4, color: k.ink)),
            const SizedBox(height: 8),
            Row(children: [
              Pill(item.state.replaceAll('-', ' '), tone: statusTone(item.state)),
              if (item.closureReason != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(item.closureReason!.replaceAll('_', ' '),
                      overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.muted)),
                ),
              ],
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// The whole message and what happened to it since.
Future<void> showHandoff(BuildContext context, QueueItem item) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SafeArea(top: false, child: _HandoffSheet(item: item)),
    );

class _HandoffSheet extends StatefulWidget {
  const _HandoffSheet({required this.item});
  final QueueItem item;
  @override
  State<_HandoffSheet> createState() => _HandoffSheetState();
}

class _HandoffSheetState extends State<_HandoffSheet> {
  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => HandoffDetail(item: widget.item, controller: scroll),
    );
  }
}

/// A handoff's whole message and what happened to it since: the sheet's content, and the Work screen's detail pane on a wide
/// page (keyed by the item there, so choosing another reads its own history).
class HandoffDetail extends StatefulWidget {
  const HandoffDetail({super.key, required this.item, this.controller, this.padding = const EdgeInsets.fromLTRB(20, 0, 20, 24), this.openSeat, this.actions});
  final QueueItem item;

  /// "Open lead": the item's destination seat, the way tapping that seat elsewhere opens it. Null: no button (the sheet).
  final ({String label, VoidCallback open})? openSeat;

  /// Reassign and Mark done, for an open item on the Work page. Null: none (the sheet, a closed item).
  final Widget? actions;
  final ScrollController? controller;
  final EdgeInsets padding;
  @override
  State<HandoffDetail> createState() => _HandoffDetailState();
}

class _HandoffDetailState extends State<HandoffDetail> {
  List<QueueTransition>? _history;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final api = AppScope.clientOf(context);
      if (api == null) return;
      try {
        final h = await api.queueTransitions(widget.item.id);
        if (mounted) setState(() => _history = h);
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final i = widget.item;
    return ListView(
        controller: widget.controller,
        padding: widget.padding,
        children: [
          Row(children: [
            Expanded(
              child: Text('${_who(i.sourceSession)} → ${_who(i.destinationSession)}', style: Theme.of(context).textTheme.titleMedium),
            ),
            if (widget.openSeat case final o?)
              OutlinedButton(onPressed: o.open, style: compactAction, child: Text(o.label)),
          ]),
          Text([if (i.created != null) ago(i.created), i.state, if (i.priority != null) i.priority!].join(' · '),
              style: TextStyle(fontSize: 12, color: k.muted)),
          if (widget.actions case final a?) Padding(padding: const EdgeInsets.only(top: 10), child: a),
          const SizedBox(height: 12),
          if (i.summary.isNotEmpty && i.body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(i.summary, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          SelectableText(i.body.isNotEmpty ? i.body : i.summary, style: const TextStyle(fontSize: 14, height: 1.45)),
          const SizedBox(height: 20),
          const SectionLabel('History · newest first'),
          if (_error != null) ErrorBanner(_error!, color: k.removed),
          if (_history == null && _error == null) const LinearProgressIndicator(),
          for (final t in (_history ?? const <QueueTransition>[]).reversed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 40, child: Text(ago(t.at), style: mono(context, size: 12))),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: '${_who(t.actor)} ', style: const TextStyle(fontWeight: FontWeight.w600)),
                      TextSpan(text: '→ ${t.state}'),
                      if (t.note != null) TextSpan(text: '\n${t.note}', style: TextStyle(color: k.muted)),
                    ]),
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ),
              ]),
            ),
        ],
    );
  }
}
