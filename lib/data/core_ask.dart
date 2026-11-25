/// One structured question an agent put to the person (OpenRig's Core app job, `GET /api/apps/v1/needs-me`).
class CoreAsk {
  CoreAsk({
    required this.requestId,
    required this.asker,
    required this.body,
    required this.revision,
    required this.episodeKey,
    required this.questions,
    required this.answers,
    required this.forms,
    this.unsupportedReason,
  });

  final String requestId;

  /// The asking seat's address (`lead@conveyor`).
  final String asker;
  final String body;

  /// The daemon's opaque `decisionRevision`, sent back with an answer.
  final String? revision;
  final String? episodeKey;
  final List<CoreQuestion> questions;

  /// questionId → the chosen option id, or `{kind: typed-reply, text}`.
  final Map<String, Object?> answers;

  /// What the daemon takes for it: `option`, `typed-reply`. Empty when it can't be answered.
  final List<String> forms;

  /// Why it can't be answered (`request_stale`), shown read-only.
  final String? unsupportedReason;

  /// The first question with no answer yet: the one an answer is bound to.
  CoreQuestion? get next => questions.where((q) => !answers.containsKey(q.id)).firstOrNull;
  bool get answerable => unsupportedReason == null && forms.isNotEmpty && next != null;

  /// What the daemon holds as the answer: each question's option label or the typed words.
  String get answerText => [
        for (final q in questions)
          if (answers[q.id] case final a?)
            a is Map ? '${a['text'] ?? ''}' : (q.options.where((o) => o.id == a).firstOrNull?.label ?? '$a')
      ].join(' · ');

  /// The seat's name without the rig: `lead`.
  String get who => asker.split('@').first;

  static CoreAsk? fromJson(Map<String, Object?> j) {
    final id = j['requestId'];
    if (id is! String) return null;
    final ans = j['answer'];
    final qs = j['questions'];
    final answers = j['humanAnswers'];
    return CoreAsk(
      requestId: id,
      asker: j['asker'] is String ? j['asker'] as String : '',
      body: j['body'] is String ? j['body'] as String : '',
      revision: j['decisionRevision'] as String?,
      episodeKey: j['episodeKey'] as String?,
      questions: [
        if (qs is List)
          for (final q in qs.whereType<Map>()) CoreQuestion.fromJson(q.cast<String, Object?>())
      ],
      answers: answers is Map ? answers.cast<String, Object?>() : const {},
      forms: ans is Map && ans['forms'] is List ? [for (final f in ans['forms'] as List) '$f'] : const [],
      unsupportedReason: j['unsupportedReason'] as String?,
    );
  }
}

class CoreQuestion {
  CoreQuestion(this.id, this.text, this.options);
  final String id;
  final String text;
  final List<({String id, String label})> options;

  static CoreQuestion fromJson(Map<String, Object?> j) => CoreQuestion(
        '${j['id']}',
        '${j['question'] ?? ''}',
        [
          if (j['options'] is List)
            for (final o in (j['options'] as List).whereType<Map>()) (id: '${o['id']}', label: '${o['label'] ?? o['id']}')
        ],
      );
}
