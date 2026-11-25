import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/core_answer.dart';
import '../../data/core_app.dart';
import '../../data/core_ask.dart';
import '../kit.dart' show navMouse;
import '../theme.dart';

/// An agent's structured question (OpenRig's Core app job) in the permission card's frame: an accent band "<agent> asks",
/// the question, then one button per option and "Reply…" for typed text. With no [onSubmit] the options are only listed.
/// [onSubmit] sends the answer and says how it ended; [onChanged] asks the screen to re-read (a partial answer to a
/// several-question ask: the next question is there).
class CoreAskCard extends StatefulWidget {
  const CoreAskCard({super.key, required this.ask, this.onSubmit, this.onChanged, this.where, this.loadSaved});
  final CoreAsk ask;
  final Future<AnswerResult> Function(Map<String, Object?> answer)? onSubmit;
  final VoidCallback? onChanged;

  /// Reads an answer saved earlier and not confirmed, so the card offers Send again for it.
  final Future<AnswerResult?> Function()? loadSaved;
  final String? where;

  @override
  State<CoreAskCard> createState() => _CoreAskCardState();
}

class _CoreAskCardState extends State<CoreAskCard> {
  final _reply = TextEditingController();
  bool _typing = false;
  bool _busy = false;
  AnswerResult? _result;

  @override
  void initState() {
    super.initState();
    widget.loadSaved?.call().then((r) {
      if (mounted && r != null && _result == null) setState(() => _result = r);
    });
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _send(Map<String, Object?> answer) async {
    if (_busy) return;
    setState(() {
      _busy = true;
    });
    final r = await widget.onSubmit!(answer);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = r;
    });
    if (r.outcome == AnswerOutcome.recorded && !r.complete) {
      _result = null;
      _reply.clear();
      _typing = false;
      widget.onChanged?.call();
    }
  }

  /// The words of the answer that was actually sent (the saved payload's), not of the last tap.
  String _sentLabel(AnswerResult r) {
    final a = r.sent;
    if (a == null) return '';
    if (a['kind'] != 'option') return '${a['text']}';
    final q = widget.ask.questions.where((q) => q.id == r.questionId).firstOrNull;
    return q?.options.where((o) => o.id == a['optionId']).firstOrNull?.label ?? '${a['optionId']}';
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final ask = widget.ask;
    final q = ask.next ?? ask.questions.lastOrNull;
    final r = _result;
    final saved = r != null && r.outcome == AnswerOutcome.pending && r.sent != null;
    final done = r != null && (r.outcome == AnswerOutcome.recorded || r.outcome == AnswerOutcome.alreadyAnswered) || !ask.answerable && ask.unsupportedReason == null && ask.next == null;
    // The permission card's buttons: 36 tall with a mouse, 48 on touch, outlined, radius 4.
    final mouse = navMouse();
    final size = ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(0, mouse ? 36 : 48)));
    const text = TextStyle(fontFamily: fontSans, fontSize: 14, fontWeight: FontWeight.w600);
    final outlined = OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10), textStyle: text, side: BorderSide(color: k.border)).merge(size);
    final filled = FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10), textStyle: text).merge(size);
    final canAnswer = widget.onSubmit != null && ask.answerable && !done;
    Widget? answer;
    if (done) {
      answer = Text(
          r?.outcome == AnswerOutcome.alreadyAnswered
              ? ['Already answered', if (r!.shown != null) r.shown!].join(' · ')
              : [if (r != null) _sentLabel(r) else ask.answerText, if (r?.message != null) r!.message!].join(' · '),
          style: TextStyle(fontSize: 13, color: k.muted));
    } else if (canAnswer && saved) {
      // Sent but not confirmed: the saved answer is the only one that can go, so it is shown and offered, nothing else.
      answer = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Saved answer: ${_sentLabel(r)}', style: const TextStyle(fontSize: 13)),
        Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Not confirmed yet: ${r.reason ?? 'try again'}', style: TextStyle(fontSize: 12, color: k.muted))),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(style: filled, onPressed: _busy ? null : () => _send(r.sent!), child: Text(_busy ? 'Sending…' : 'Send again'))),
        ),
      ]);
    } else if (canAnswer) {
      answer = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (ask.forms.contains('option') && q != null)
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final o in q.options)
              OutlinedButton(style: outlined, onPressed: _busy ? null : () => _send(optionAnswer(o.id)), child: Text(o.label)),
            if (ask.forms.contains('typed-reply'))
              OutlinedButton(style: outlined, onPressed: _busy ? null : () => setState(() => _typing = !_typing), child: const Text('Reply…')),
          ]),
        if (_typing || !ask.forms.contains('option'))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Expanded(child: TextField(controller: _reply, minLines: 1, maxLines: 4, decoration: const InputDecoration(hintText: 'Your reply'))),
              const SizedBox(width: 8),
              FilledButton(
                  style: filled,
                  onPressed: _busy ? null : () => _reply.text.trim().isEmpty ? null : _send(typedAnswer(_reply.text)),
                  child: const Text('Send')),
            ]),
          ),
        if (_busy) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Sending…', style: TextStyle(fontSize: 12, color: k.muted))),
        if (r?.outcome == AnswerOutcome.notSent)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text('Not sent, try again: ${r!.reason}', style: TextStyle(fontSize: 12, color: k.muted))),
        if (r?.outcome == AnswerOutcome.refused)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text('${r!.reason}', style: TextStyle(fontSize: 12, color: k.muted))),
      ]);
    }
    return Semantics(
      container: true,
      label: '${ask.who} asks: ${q?.text ?? ask.body}',
      child: Container(
        decoration: BoxDecoration(
            color: k.surface, border: Border.all(color: done ? k.border : k.accent), borderRadius: BorderRadius.circular(kRadius)),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            color: done ? k.surface : Color.alphaBlend(k.accent.withValues(alpha: .10), k.surface),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: done ? '${ask.who} asked · Answered' : '${ask.who} asks', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              if (widget.where != null) TextSpan(text: '  ${widget.where}', style: TextStyle(fontSize: 12, color: k.muted)),
            ]), maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (ask.body.isNotEmpty && q?.text != ask.body)
                Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(ask.body, style: TextStyle(fontSize: 13, color: k.muted))),
              if (q != null) Text(q.text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              if (widget.onSubmit == null && q != null)
                for (final o in q.options)
                  Padding(padding: const EdgeInsets.only(top: 6), child: Text('· ${o.label}', style: TextStyle(fontSize: 13, color: k.muted))),
              if (ask.unsupportedReason case final why?)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text(why, style: TextStyle(fontSize: 12, color: k.faint))),
              if (answer != null) Padding(padding: const EdgeInsets.only(top: 12), child: answer),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Why this host shows no questions, as one muted line: no person to answer as (with the command that makes one, and
/// Copy), or the daemon's reason a credential couldn't be issued.
class CoreAppNote extends StatelessWidget {
  const CoreAppNote(this.app, {super.key, this.host});
  final CoreApp app;
  final String? host;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final noPerson = app.state == CoreAppState.noPerson;
    final text = noPerson ? 'Answering questions here needs a person on this host' : 'Questions can\'t be answered here: ${app.reason}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(host == null ? text : '$text ($host)', style: TextStyle(fontSize: 12, color: k.muted)),
        if (noPerson)
          Row(children: [
            Expanded(child: SelectableText(registerPersonCommand, style: mono(context, size: 11, color: k.muted))),
            TextButton(onPressed: () => Clipboard.setData(const ClipboardData(text: registerPersonCommand)), child: const Text('Copy')),
          ]),
      ]),
    );
  }
}
