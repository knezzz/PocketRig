import 'dart:async';
import 'dart:convert';

import 'package:borealis/borealis.dart';
import 'package:http/http.dart' as http;

import '../data/ux_log.dart';

/// The client the app talks to daemons with: recorded in Borealis's Network
/// tab in every build, release included (a debug aid, eaa4af0): request and
/// response bodies, so messages sent to agents too, stay in memory while the
/// app runs. [inner] does the sending (for daemons: a `RoutedClient` that can
/// fall back to SSH).
http.Client newHttpClient([http.Client? inner]) => WiretapClient(inner);

/// Mirrors every request and response into [WiretapStore.instance]. Borealis
/// only ships a Dio interceptor; this is the `package:http` equivalent.
class WiretapClient extends http.BaseClient {
  WiretapClient([http.Client? inner]) : _inner = inner ?? http.Client();
  final http.Client _inner;
  static int _seq = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final store = WiretapStore.instance;
    var entry = WiretapEntry(
      id: '${_seq++}',
      method: request.method,
      uri: request.url,
      requestHeaders: _redactHeaders(request.headers),
      requestBody: request is http.Request ? _decode(request.bodyBytes) : null,
      timestamp: DateTime.now(),
    );
    store.add(entry);
    final http.StreamedResponse res;
    try {
      res = await _inner.send(request);
    } catch (e) {
      store.update(entry.copyWith(error: e, responseTimestamp: DateTime.now(), isLoading: false));
      uxLog.call('${request.method} ${request.url.path}', DateTime.now().difference(entry.timestamp), error: e);
      rethrow;
    }
    entry = entry.copyWith(statusCode: res.statusCode, responseHeaders: res.headers, responseTimestamp: DateTime.now());
    uxLog.call('${request.method} ${request.url.path}', DateTime.now().difference(entry.timestamp),
        status: res.statusCode);
    // An SSE stream never ends, so it's complete once the headers are in.
    if (res.headers['content-type']?.contains('text/event-stream') ?? false) {
      store.update(entry.copyWith(responseBody: '<event stream>', isLoading: false));
      return res;
    }
    final bytes = <int>[];
    final body = res.stream.transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (chunk, sink) {
        bytes.addAll(chunk);
        sink.add(chunk);
      },
      handleError: (e, st, sink) {
        store.update(entry.copyWith(error: e, isLoading: false));
        sink.addError(e, st);
      },
      handleDone: (sink) {
        store.update(entry.copyWith(
            responseBody: request.url.path.startsWith('/api/apps/v1/credentials') ? '<redacted: app credential>' : _decode(bytes),
            isLoading: false));
        sink.close();
      },
    ));
    return http.StreamedResponse(body, res.statusCode,
        contentLength: res.contentLength,
        request: res.request,
        headers: res.headers,
        isRedirect: res.isRedirect,
        persistentConnection: res.persistentConnection,
        reasonPhrase: res.reasonPhrase);
  }

  /// The headers as recorded: a bearer token never reaches the inspector (it shows in release builds too).
  static Map<String, String> _redactHeaders(Map<String, String> h) =>
      {for (final e in h.entries) e.key: e.key.toLowerCase() == 'authorization' ? '<redacted>' : e.value};

  /// JSON when it parses (Borealis pretty-prints it), else the raw text.
  static Object? _decode(List<int> bytes) {
    if (bytes.isEmpty) return null;
    final text = utf8.decode(bytes, allowMalformed: true);
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }

  @override
  void close() => _inner.close();
}
