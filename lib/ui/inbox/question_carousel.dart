import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/question_card.dart';
import '../kit.dart';
import '../theme.dart';

/// A seat's questions one at a time: "1 of 3", page dots, ‹ ›, the options
/// as radio rows (checkboxes for pick-any) with an Other field, then
/// "Next question" until the last sends them all together ("Send answers"); the count is in the header only.
/// The one question UI: the Inbox card shows it as is, the chat wraps it in a framed card ([QuestionCard]).
class QuestionCarousel extends StatefulWidget {
  const QuestionCarousel({
    super.key,
    required this.seatName,
    required this.questions,
    required this.onSend,
    required this.onDecline,
    this.busy = false,
    this.otherOnMulti = true,
  });
  final String seatName;
  final List<AskQuestion> questions;

  /// The options picked per question (0-based) and what was typed in Other (null for none). A returned Future keeps the
  /// card busy until it completes (a second tap can't send again) and frees it if the answer failed.
  final FutureOr<void> Function(List<Set<int>> picks, List<String?> others) onSend;
  final VoidCallback onDecline;
  final bool busy;

  /// Whether a pick-any question takes words too. The Inbox sends words as a message, so it can; the chat answers through
  /// the menu's "Type something" row, which only a single-select question has.
  final bool otherOnMulti;

  @override
  State<QuestionCarousel> createState() => _QuestionCarouselState();
}

class _QuestionCarouselState extends State<QuestionCarousel> {
  late final _picks = [for (final _ in widget.questions) <int>{}];
  late final _others = [for (final _ in widget.questions) TextEditingController()];
  var _at = 0;
  bool _sending = false;

  bool get _off => widget.busy || _sending;

  /// What was typed for question [i], null when nothing (or when this question takes no words).
  String? _words(int i) {
    final t = _others[i].text.trim();
    return t.isEmpty || (widget.questions[i].multi && !widget.otherOnMulti) ? null : t;
  }

  Future<void> _send() async {
    if (_off) return;
    setState(() => _sending = true);
    try {
      await widget.onSend([for (final p in _picks) Set.of(p)], [for (var i = 0; i < _picks.length; i++) _words(i)]);
    } finally {
      // A failed answer leaves the card as it was, ready for another try.
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    for (final c in _others) {
      c.dispose();
    }
    super.dispose();
  }

  bool _answered(int i) => _picks[i].isNotEmpty || _words(i) != null;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final qs = widget.questions;
    final n = qs.length;
    final q = qs[_at];
    final last = _at == n - 1;
    final ready = last ? List.generate(n, _answered).every((x) => x) : _answered(_at);
    Widget arrow(String label, String glyph, VoidCallback? on) => Semantics(
          button: true,
          enabled: on != null,
          label: label,
          onTap: on,
          excludeSemantics: true,
          child: InkResponse(
            onTap: on,
            radius: 20,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Center(
                  child: Text(glyph, style: TextStyle(fontSize: 20, color: on == null ? k.faint : k.ink))),
            ),
          ),
        );
    return Semantics(
      container: true,
      label: 'Questions from ${widget.seatName}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (n > 1)
          Row(children: [
            arrow('Previous question', '‹', _at > 0 ? () => setState(() => _at--) : null),
            Expanded(
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < n; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: kEaseOut,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    width: i == _at ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                        color: i == _at ? k.ink : k.border, borderRadius: BorderRadius.circular(3)),
                  ),
              ]),
            ),
            arrow('Next question', '›', _at < n - 1 ? () => setState(() => _at++) : null),
          ]),
        Semantics(
          label: 'Question ${_at + 1} of $n',
          container: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              [if (n > 1) '${_at + 1} of $n', if (q.header.isNotEmpty) q.header].join(' · ').toUpperCase(),
              style: sectionLabelStyle(context),
            ),
            const SizedBox(height: 4),
            Text(q.question, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.4)),
            if (q.multi) Text('Pick any', style: TextStyle(fontSize: 12, color: k.muted)),
          ]),
        ),
        const SizedBox(height: 8),
        // A bordered list whose row hairlines are the frame's own colour: the kit's divider tone vanishes in the dark theme.
        Material(
          color: k.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius), side: BorderSide(color: k.border)),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var o = 0; o < q.options.length; o++) ...[
              if (o > 0) Divider(color: k.border),
              _option(k, o),
            ],
            if (!q.multi || widget.otherOnMulti) ...[
              if (q.options.isNotEmpty) Divider(color: k.border),
              _other(k),
            ],
          ]),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _off ? null : widget.onDecline,
              style: OutlinedButton.styleFrom(side: BorderSide(color: k.border), padding: const EdgeInsets.symmetric(horizontal: 8)),
              child: Text(n > 1 ? 'Decline all' : 'Decline', maxLines: 1, softWrap: false),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: FilledButton(
              onPressed: _off || !ready
                  ? null
                  : last
                      ? _send
                      : () => setState(() => _at++),
              style: FilledButton.styleFrom(),
              child: Text(last ? (n > 1 ? 'Send answers' : 'Send answer') : 'Next question'),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _option(Tokens k, int o) {
    final q = widget.questions[_at];
    final (label, description) = q.options[o];
    final on = _picks[_at].contains(o);
    void pick() => setState(() {
          final p = _picks[_at];
          if (q.multi) {
            on ? p.remove(o) : p.add(o);
          } else {
            p
              ..clear()
              ..add(o);
            _others[_at].clear();
          }
        });
    // One node per option: the RowTile's own (label, button, tap) with the checked state merged in.
    return Semantics(
      checked: on,
      inMutuallyExclusiveGroup: !q.multi,
      child: RowTile(
        minHeight: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        onTap: pick,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _mark(k, on, q.multi),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              if (description != null && description.isNotEmpty)
                Text(description, style: TextStyle(fontSize: 12, color: k.muted)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _other(Tokens k) {
    final c = _others[_at];
    final on = c.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _mark(k, on, false),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Other', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            TextField(
              key: ValueKey('other$_at'),
              controller: c,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 13),
              onChanged: (v) => setState(() {
                if (v.trim().isNotEmpty && !widget.questions[_at].multi) _picks[_at].clear();
              }),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Type your own answer',
                hintStyle: TextStyle(color: k.faint),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _mark(Tokens k, bool on, bool multi) => Padding(
        padding: const EdgeInsets.only(top: 1),
        child: multi
            ? Icon(on ? Icons.check_box : Icons.check_box_outline_blank, size: 18, color: on ? k.ink : k.muted)
            : Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: on ? k.ink : k.muted, width: on ? 5 : 1.5),
                ),
              ),
      );
}
