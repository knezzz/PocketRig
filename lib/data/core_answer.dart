import 'dart:convert';
import 'dart:math';

import '../api/openrig_client.dart';
import '../models.dart';
import 'core_app.dart';
import 'core_ask.dart';
import 'host_store.dart';

/// How an answer ended up.
enum AnswerOutcome {
  /// The daemon recorded it (the whole answer, or one of several questions: see [AnswerResult.complete]).
  recorded,

  /// Someone already answered it: the card shows the current answer from a re-read.
  alreadyAnswered,

  /// Not confirmed: saved with its id; Send again sends the very same one.
  pending,

  /// Nothing was sent or saved (no credential just now): the options stay, try again.
  notSent,

  /// The daemon refused it for good (not retried).
  refused,
}

class AnswerResult {
  const AnswerResult(this.outcome, {this.complete = true, this.message, this.reason, this.sent, this.questionId, this.shown});
  final AnswerOutcome outcome;

  /// The answer actually sent (the saved payload's, which may not be the tap that started this) and its question.
  final Map<String, Object?>? sent;
  final String? questionId;

  /// For [AnswerOutcome.alreadyAnswered]: what the daemon holds now, from a re-read.
  final String? shown;

  /// False when other questions of the ask are still open.
  final bool complete;

  /// The owner's own words about it, when it has any.
  final String? message;
  final String? reason;
}

String newAnswerId() => base64Url.encode(List.generate(18, (_) => Random.secure().nextInt(256))).replaceAll('=', '');

/// The `answer` object: an option, or typed text.
Map<String, Object?> optionAnswer(String optionId) => {'kind': 'option', 'optionId': optionId};
Map<String, Object?> typedAnswer(String text) => {'kind': 'typed-reply', 'text': text.trim()};

/// Sends [answer] to [ask]'s first unanswered question. The id and payload are saved before the POST and reused by every
/// retry: a lost response or a 503 sends the same bytes again, and a new id is never made for a decision already sent.
/// [backoff] is the wait before each retry of a 503.
Future<AnswerResult> submitCoreAnswer(HostStore store, Host host, CoreAsk ask, Map<String, Object?> answer,
    {List<Duration> backoff = const [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)]}) async {
  final q = ask.next;
  if (q == null) return const AnswerResult(AnswerOutcome.refused, reason: 'Nothing left to answer.');
  final api = OpenRigClient.create(host);
  // The token is read from storage here, for this call only: no screen holds it.
  final app = await coreAppFor(store, host);
  if (app.state != CoreAppState.ready) return AnswerResult(AnswerOutcome.notSent, reason: app.reason ?? 'No credential.');
  var token = app.token!;
  var saved = await store.pendingAnswer(host.id, ask.requestId);
  if (saved == null) {
    saved = {
      'answerId': newAnswerId(),
      'payload': {
        'job': 'human-answer',
        'actor': app.actor,
        'requestId': ask.requestId,
        'questionId': q.id,
        'episodeKey': ask.episodeKey,
        'expectedRevision': ask.revision,
        'answer': answer,
      },
    };
    await store.setPendingAnswer(host.id, ask.requestId, saved);
  }
  final id = saved['answerId'] as String;
  final payload = (saved['payload'] as Map).cast<String, Object?>();
  final sent = (payload['answer'] as Map).cast<String, Object?>();
  final qid = payload['questionId'] as String?;
  AnswerResult res(AnswerOutcome o, {bool complete = true, String? message, String? reason, String? shown}) =>
      AnswerResult(o, complete: complete, message: message, reason: reason, sent: sent, questionId: qid, shown: shown);
  var reauthed = false;
  for (var attempt = 0;; attempt++) {
    try {
      final r = await api.appCall('POST', '/api/apps/v1/answers/$id', token, body: payload);
      final j = r.json is Map ? (r.json as Map).cast<String, Object?>() : const <String, Object?>{};
      if (r.status == 200) {
        await store.setPendingAnswer(host.id, ask.requestId, null);
        final sub = j['submission'] is Map ? (j['submission'] as Map).cast<String, Object?>() : const <String, Object?>{};
        return res(AnswerOutcome.recorded, complete: sub['outcome'] != 'recorded', message: sub['message'] as String?);
      }
      if (r.status == 401 || r.status == 403) {
        if (reauthed) return res(AnswerOutcome.pending, reason: 'The daemon refused the credential (${r.status}).');
        reauthed = true;
        final again = await coreAppFor(store, host, forceNew: true);
        if (again.state != CoreAppState.ready) return res(AnswerOutcome.pending, reason: again.reason ?? 'No credential.');
        token = again.token!;
        continue;
      }
      if (r.status == 409) {
        await store.setPendingAnswer(host.id, ask.requestId, null);
        // Someone else's answer stands: show what the daemon holds now.
        String? now;
        try {
          final rr = await api.appCall('GET', '/api/apps/v1/requests/${ask.requestId}', token, query: {'actor': '${payload['actor']}'});
          final cur = rr.json is Map ? CoreAsk.fromJson((rr.json as Map).cast<String, Object?>()) : null;
          final t = cur?.answerText ?? '';
          now = t.isEmpty ? null : t;
        } catch (_) {}
        return res(AnswerOutcome.alreadyAnswered, reason: j['code'] as String? ?? j['error'] as String?, shown: now);
      }
      if (r.status == 503) {
        // incomplete / unknown: the daemon may have kept it. Read the receipt before sending again.
        final got = await api.appCall('GET', '/api/apps/v1/answers/$id', token, query: {'actor': '${payload['actor']}'});
        final gj = got.json is Map ? (got.json as Map).cast<String, Object?>() : const <String, Object?>{};
        final sub = gj['submission'] is Map ? (gj['submission'] as Map).cast<String, Object?>() : const <String, Object?>{};
        if (got.status == 200 && sub['state'] == 'committed') {
          await store.setPendingAnswer(host.id, ask.requestId, null);
          return res(AnswerOutcome.recorded, complete: sub['outcome'] != 'recorded', message: sub['message'] as String?);
        }
        if (attempt < backoff.length) {
          await Future<void>.delayed(backoff[attempt]);
          continue;
        }
        return res(AnswerOutcome.pending, reason: 'The daemon is busy; your answer is saved.');
      }
      // Anything else is a refusal of this exact request: it won't change by sending it again.
      await store.setPendingAnswer(host.id, ask.requestId, null);
      return res(AnswerOutcome.refused, reason: daemonErrorMessage(r.status, r.json, host: host.address));
    } on OpenRigException catch (e) {
      // No response: it may or may not have arrived. Keep the id; Retry sends the same one.
      return res(AnswerOutcome.pending, reason: e.message);
    }
  }
}

/// The answer saved for [ask] before and not confirmed (the app closed, or the daemon was busy), as a pending result; null
/// when there is none. A card shows it on build so it offers Send again instead of the options.
Future<AnswerResult?> savedCoreAnswer(HostStore store, Host host, CoreAsk ask) async {
  final saved = await store.pendingAnswer(host.id, ask.requestId);
  final payload = saved?['payload'];
  if (payload is! Map || payload['answer'] is! Map) return null;
  return AnswerResult(AnswerOutcome.pending,
      reason: 'it was saved before', sent: (payload['answer'] as Map).cast<String, Object?>(), questionId: payload['questionId'] as String?);
}
