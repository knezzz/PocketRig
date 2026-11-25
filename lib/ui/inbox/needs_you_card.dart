import 'package:flutter/material.dart';

import '../../models.dart';
import '../../terminal/transport.dart';
import '../answer_bar.dart';
import '../common.dart';
import '../progress_bar.dart';
import '../status_shape.dart';
import '../usage_strip.dart' show compactsSoon, contextColor, contextWeight;
import '../permission_card.dart';
import '../kit.dart' show AgentRow, sectionLabelStyle;
import '../theme.dart';
import 'answering.dart';
import 'question_carousel.dart';

/// "wants to run a command", "asked 3 questions": what a waiting seat wants.
String wantsPhrase(PermissionAsk ask, {int questions = 0}) {
  if (questions > 1) return 'asked $questions questions';
  if (questions == 1) return 'asked a question';
  if (!ask.isPermission) {
    return ask.detail == 'Asked you to pick an option' ? 'asked you to pick an option' : 'is waiting for you';
  }
  return switch (ask.tool) {
    'Bash' => 'wants to run a command',
    'Edit' || 'Write' || 'MultiEdit' || 'NotebookEdit' => 'wants to edit a file',
    'WebFetch' => 'wants to fetch a page',
    null => 'needs approval',
    final t => 'wants to use $t',
  };
}

/// "claude · opus · mode ask".
String seatFacts(Seat s) => [
      switch (s.runtime) { 'claude-code' => 'claude', final r? => r, null => 'agent' },
      if (s.model case final m? when m.isNotEmpty) m,
      if (PermissionMode.fromWire(s.permissionMode)?.label ?? s.permissionMode case final m?) 'mode ${m.toLowerCase()}',
    ].join(' · ');

/// One Needs-you card in the Inbox, answerable where it is: who and what it
/// wants, where it runs, the exact command, the context to decide on, then
/// the answer (the shared [AnswerBar], the question carousel, or a reply),
/// and Terminal / Open in chat.
class NeedsYouCard extends StatefulWidget {
  const NeedsYouCard({
    super.key,
    required this.host,
    required this.seat,
    required this.where,
    this.age,
    this.pending,
    this.lastSaid,
    this.branch,
    this.loose,
    this.onTerminal,
    this.onChat,
    this.onAnswered,
    this.expanded = true,
    this.selected = false,
    this.onToggle,
  });

  final Host host;
  final Seat seat;

  /// "web-rig › dev › app · homelab".
  final String where;
  final DateTime? age;
  final PendingAsk? pending;
  final String? lastSaid;
  final String? branch;

  /// Set for an agent outside a rig: answered through its tmux pane, Allow or Deny only.
  final LooseAgent? loose;
  final VoidCallback? onTerminal;
  final VoidCallback? onChat;

  /// The answer went out: the screen can drop the card before the next refresh.
  final VoidCallback? onAnswered;

  /// Open: everything the agent asked, its recent output, its context and the answer. Closed: one line, to tap open.
  final bool expanded;

  /// The row is the open one in a list beside its detail (the Mac): drawn with the accent border.
  final bool selected;

  /// The header's tap: open or close in place (a phone), or pick the item (the Mac list). Null: not tappable.
  final VoidCallback? onToggle;

  @override
  State<NeedsYouCard> createState() => _NeedsYouCardState();
}

class _NeedsYouCardState extends State<NeedsYouCard> {
  bool _busy = false;
  final _reply = TextEditingController();

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _run(Future<bool> Function() send) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await send();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) widget.onAnswered?.call();
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final s = widget.seat;
    final loose = widget.loose;
    final ask = askOf(s, widget.pending);
    final questions = widget.pending?.questions;
    final name = loose?.name ?? s.logicalId;
    final permission = loose != null ? loose.isPermission : ask.isPermission && questions == null;
    final wants = wantsPhrase(ask, questions: questions?.length ?? 0);
    final command = switch (ask) {
      PermissionAsk(tool: final t?, :final detail) when t != 'Bash' => '$t · $detail',
      PermissionAsk(:final detail) => detail,
    };
    final open = widget.expanded;
    final age = widget.age == null ? null : ago(widget.age);
    final rig = widget.where.split(' › ').first.split(' · ').first;
    const status = Status.needsYou;
    final detail = (permission ? command : ask.detail).split('\n').first;
    final summary = questions != null
        ? wants
        : permission
            ? [wants, detail].where((x) => x.isNotEmpty).join(': ')
            : (detail.isEmpty ? wants : detail);
    // One agent row, as everywhere: only the open card takes the accent tint.
    Widget header() => AgentRow(
          name: name,
          status: status,
          runtime: loose?.runtime ?? s.runtime,
          extra: open ? widget.where : rig,
          task: open ? '${permission ? 'Permission' : 'Question'} · ${permission || detail.isEmpty ? wants : detail}' : summary,
          age: age,
          ageOnTitle: true,
          tint: open ? Color.alphaBlend(k.accent.withValues(alpha: .10), k.surface) : null,
          onTap: widget.onToggle,
          expanded: widget.onToggle == null ? null : open,
          // Who, what, where, how long, and whether it is open: the row is one node for a screen reader.
          openLabel: [
            '$name $wants',
            widget.where,
            if (age != null) 'waiting $age',
            if (widget.onToggle != null) open ? 'expanded' : 'collapsed',
          ].where((x) => x.isNotEmpty).join(', '),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        container: true,
        label: '$name $wants',
        child: Material(
          color: k.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadius),
              side: BorderSide(color: open || widget.selected ? k.accent : k.border)),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            header(),
            if (open) ...[
              Padding(
                // The links row is drawn 11dp up (below), so its own space under it is not added to the padding.
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (questions == null) ...[
                    if (permission) ...[_label(context, wants), const SizedBox(height: 6), PermissionCode(command)] else _code(context, ask.detail, isMono: false),
                    const SizedBox(height: 10),
                  ],
                  _grid(context),
                  const SizedBox(height: 10),
                  ..._answer(context, ask, questions, permission),
                  // A rig seat's permission has Terminal and Open in chat on the answer's own action row.
                  if (!(permission && loose == null && questions == null)) _links(context),
                ]),
              ),
              if (widget.pending?.recent case final lines? when lines.isNotEmpty) ...[
                Divider(height: 1, color: k.border),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _label(context, 'Recent output'),
                    const SizedBox(height: 6),
                    for (final (text, said) in lines)
                      Text(said ? '▸ $text' : text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: mono(context, size: 12, color: said ? k.ink : k.muted)),
                  ]),
                ),
              ],
              if (s.contextUsedPercent case final c?) ...[
                Divider(height: 1, color: k.border),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: Row(children: [
                    Text('CONTEXT', style: mono(context, size: 10, color: k.muted).copyWith(letterSpacing: 0.5)),
                    const SizedBox(width: 12),
                    SizedBox(width: 120, child: ContextBar(c, height: 4, label: false)),
                    const SizedBox(width: 10),
                    Text(c >= 80 ? '${c.round()}% · $compactsSoon' : '${c.round()}%',
                        style: mono(context, size: 12, color: contextColor(c, k)).copyWith(fontWeight: contextWeight(c))),
                  ]),
                ),
              ],
            ],
          ]),
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Text(text.toUpperCase(), style: sectionLabelStyle(context, size: 10));

  List<Widget> _answer(BuildContext context, PermissionAsk ask, List<dynamic>? questions, bool permission) {
    final k = Tokens.of(context);
    final s = widget.seat;
    final host = widget.host;
    final loose = widget.loose;
    if (loose != null) {
      if (!loose.inTmux) {
        return [_note(context, 'Not in tmux, so it can\'t be answered from here. Answer it at the Mac.')];
      }
      if (!loose.isPermission) {
        return [_note(context, 'Waiting for your input. Open it to reply.')];
      }
      return [
        Align(
          alignment: Alignment.centerRight,
          child: AnswerBar(
            compact: true,
            busy: _busy,
            onDeny: () => _run(() => answerLooseOn(context, host, loose, allow: false)),
            onAllow: () => _run(() => answerLooseOn(context, host, loose, allow: true)),
          ),
        ),
      ];
    }
    if (s.sessionName == null) return [_note(context, 'This seat has no session to answer.')];
    final qs = widget.pending?.questions;
    if (qs != null) {
      return [
        QuestionCarousel(
          seatName: s.logicalId,
          questions: qs,
          busy: _busy,
          onSend: (picks, others) => _run(() => sendQuestionAnswers(context, host, s, qs, picks, [for (final o in others) o ?? ''])),
          onDecline: () => _run(() => answerSeatOn(context, host, s, SeatAnswer.deny)),
        ),
      ];
    }
    if (permission) {
      final auto = s.isClaude && PermissionMode.fromWire(s.permissionMode) != PermissionMode.auto;
      return [
        AnswerBar(
          busy: _busy,
          alwaysScope: ask.alwaysScope,
          onDeny: () => _run(() => answerSeatOn(context, host, s, SeatAnswer.deny)),
          onAlways: () =>
              _run(() => answerSeatOn(context, host, s, SeatAnswer.allowAlways, scope: ask.alwaysScope)),
          onAllow: () => _run(() => answerSeatOn(context, host, s, SeatAnswer.allowOnce)),
          onDenyWithNote: () => _run(() => denyWithNoteOn(context, host, s)),
          onAllowAuto: auto ? () => _run(() => allowAndAutoOn(context, host, s)) : null,
          extras: [
            if (widget.onTerminal != null) ('Terminal', widget.onTerminal),
            if (widget.onChat != null) ('Open in chat ›', widget.onChat),
          ],
        ),
      ];
    }
    // A question the log doesn't spell out: reply in words.
    return [
      Row(children: [
        Expanded(
          child: TextField(
            controller: _reply,
            enabled: !_busy,
            minLines: 1,
            maxLines: 3,
            style: const TextStyle(fontSize: 13),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendReply(context),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Reply to ${s.logicalId}…',
              hintStyle: TextStyle(color: k.faint),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: BorderSide(color: k.border)),
              enabledBorder:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: BorderSide(color: k.border)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _busy ? null : () => _sendReply(context),
          child: const Text('Send'),
        ),
      ]),
    ];
  }

  void _sendReply(BuildContext context) {
    final text = _reply.text.trim();
    if (text.isEmpty) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final k = Tokens.of(context);
    _run(() async {
      final ok = await sendTo(messenger, k, widget.host, widget.seat, text, 'Sent · ${widget.seat.logicalId}');
      if (ok) _reply.clear();
      return ok;
    });
  }

  Widget _code(BuildContext context, String text, {bool isMono = true}) {
    final k = Tokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      // Darker than the card in both themes (the dark theme's fill is the card's own colour).
      decoration: BoxDecoration(
          color: k.isDark ? Color.lerp(k.surface, Colors.black, .3) : k.fill, borderRadius: BorderRadius.circular(kRadius)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 140),
        child: SingleChildScrollView(
          child: Text(text,
              style: isMono ? mono(context, size: 12, color: k.ink) : const TextStyle(fontSize: 14, height: 1.4)),
        ),
      ),
    );
  }

  Widget _note(BuildContext context, String text) =>
      Text(text, style: TextStyle(fontSize: 12, color: Tokens.of(context).muted));

  Widget _grid(BuildContext context) {
    final k = Tokens.of(context);
    final s = widget.seat;
    final p = widget.pending;
    final facts = s.rigId.isEmpty && widget.loose != null ? null : seatFacts(s);
    final rows = <(String, Widget)>[
      if (p?.why case final why?) ('Why', Text(why, style: const TextStyle(fontSize: 12))),
      if (s.cwd ?? widget.loose?.cwd case final cwd?)
        ('In', Text(displayPath(cwd), style: mono(context, size: 11, color: k.ink))),
      if (widget.branch case final b?) ('Branch', Text(b, style: mono(context, size: 11, color: k.ink))),
      if (facts != null && facts.isNotEmpty) ('Seat', Text(facts, style: const TextStyle(fontSize: 12))),
      if (p?.task case final t?) ('Task', Text(t, style: const TextStyle(fontSize: 12))),
      if (widget.lastSaid case final said? when said.trim().isNotEmpty && (p?.recent.isEmpty ?? true))
        (
          'Last said',
          Text('“${said.replaceAll(RegExp(r'\s+'), ' ').trim()}”',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: k.muted)),
        ),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (label, value) in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 72,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(label.toUpperCase(), style: sectionLabelStyle(context, size: 10)),
              ),
            ),
            Expanded(child: value),
          ]),
        ),
    ]);
  }

  Widget _links(BuildContext context) {
    final k = Tokens.of(context);
    Widget link(String label, VoidCallback? on, {bool quiet = false}) => TextButton(
          onPressed: on,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            foregroundColor: quiet ? k.muted : k.ink,
            textStyle: TextStyle(
                fontFamily: fontSans,
                fontSize: 12, fontWeight: quiet ? FontWeight.w500 : FontWeight.w600, decoration: TextDecoration.underline),
          ).merge(compactAction),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        );
    return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
      if (widget.onTerminal != null) link('Terminal', widget.onTerminal),
      if (widget.onTerminal != null && widget.onChat != null) const SizedBox(width: 10),
      if (widget.onChat != null) link('Open in chat ›', widget.onChat),
    ]);
  }
}
