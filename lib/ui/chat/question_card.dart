import 'dart:async';

import 'package:flutter/material.dart';

import '../../chat/transcript.dart';
import '../../terminal/transport.dart' show TypedAnswer;
import '../inbox/question_carousel.dart';
import '../kit.dart';
import '../theme.dart';

/// One question from an AskUserQuestion call.
class AskQuestion {
  const AskQuestion(this.question, this.header, this.multi, this.options);
  final String question;
  final String header;
  final bool multi;
  final List<(String label, String? description)> options;

  /// The questions a waiting AskUserQuestion call asks; null for other calls
  /// or input this can't answer by number keys.
  static List<AskQuestion>? from(ToolCall? c) {
    final qs = c?.name == 'AskUserQuestion' ? c!.input['questions'] : null;
    if (qs is! List || qs.isEmpty) return null;
    final out = <AskQuestion>[];
    for (final q in qs) {
      final opts = q is Map ? q['options'] : null;
      // Digits pick options, and the menu adds "Type something" as one more.
      if (opts is! List || opts.isEmpty || opts.length > 8) return null;
      out.add(AskQuestion('${q['question'] ?? ''}', '${q['header'] ?? ''}', q['multiSelect'] == true, [
        for (final o in opts) o is Map ? ('${o['label'] ?? ''}', o['description'] as String?) : ('$o', null),
      ]));
    }
    return out;
  }
}

/// The tmux keys that answer Claude Code's question menu with [picks] (the
/// options chosen per question, 0-based). Checked against Claude Code 2.1: a
/// digit picks a single-select answer and moves on; digits toggle a
/// multi-select and Tab moves on; with more than one question or any
/// multi-select a review page follows, where 1 submits.
List<String> questionKeys(List<AskQuestion> qs, List<Set<int>> picks) => [
      for (final s in questionSteps(qs, picks, [for (final _ in qs) null])) s as String
    ];

/// [questionKeys], with [other] answers: a question answered in words
/// picks the menu's "Type something" row (one past the options), then types
/// the text and presses Enter ([TypedAnswer]). Each step is a tmux key name
/// or a [TypedAnswer].
// shortcut: the "Type something" row is reached by its digit, as Claude Code 2.1 numbers it; not checked for a
// question past the first.
List<Object> questionSteps(List<AskQuestion> qs, List<Set<int>> picks, List<String?> other) => [
      for (var i = 0; i < qs.length; i++)
        if (other[i] case final text? when text.trim().isNotEmpty && !qs[i].multi) ...[
          '${qs[i].options.length + 1}',
          TypedAnswer(text.trim().replaceAll(RegExp(r'\s*\n\s*'), ' ')), // the field may submit at a newline
        ] else ...[
          for (final o in picks[i].toList()..sort()) '${o + 1}',
          if (qs[i].multi) 'Tab',
        ],
      if (qs.length > 1 || qs.first.multi) '1',
    ];

/// The agent's questions in the conversation: the Inbox's [QuestionCarousel] (one question at a time, Next, Send answers,
/// Decline) in a framed card. A pick-any question takes no words here: the menu's "Type something" row is single-select only.
class QuestionCard extends StatelessWidget {
  const QuestionCard(
      {super.key, required this.seatName, required this.questions, required this.onSend, required this.onDecline});
  final String seatName;
  final List<AskQuestion> questions;

  /// The chosen options per question, 0-based, and per question the words typed under "Other" (null where an option was
  /// picked). A returned Future keeps the card busy until it completes, so a second tap can't send again.
  final FutureOr<void> Function(List<Set<int>> picks, List<String?> other) onSend;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      // Sized to its content even in a slot of fixed height.
      child: Align(
        heightFactor: 1,
        child: SizedBox(
          width: double.infinity,
          child: Panel(
            borderColor: k.accent,
            padding: const EdgeInsets.all(12),
            child: QuestionCarousel(
              seatName: seatName,
              questions: questions,
              onSend: onSend,
              onDecline: onDecline,
              otherOnMulti: false,
            ),
          ),
        ),
      ),
    );
  }
}
