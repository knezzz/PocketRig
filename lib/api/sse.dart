import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One Server-Sent Events frame.
class SseFrame {
  SseFrame({this.id, this.event = 'message', required this.data});
  final String? id;
  final String event;
  final String data;
}

/// Turns a stream of text lines into SSE frames (the WHATWG framing:
/// `field: value` lines, a blank line ends a frame, `:` lines are comments).
class SseParser extends StreamTransformerBase<String, SseFrame> {
  const SseParser();

  @override
  Stream<SseFrame> bind(Stream<String> lines) async* {
    String? id;
    String event = 'message';
    final data = StringBuffer();
    var hasData = false;
    await for (final raw in lines) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (line.isEmpty) {
        if (hasData) yield SseFrame(id: id, event: event, data: data.toString());
        event = 'message';
        data.clear();
        hasData = false;
        continue;
      }
      if (line.startsWith(':')) continue;
      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'id':
          id = value;
        case 'event':
          event = value;
        case 'data':
          if (hasData) data.write('\n');
          data.write(value);
          hasData = true;
      }
    }
    if (hasData) yield SseFrame(id: id, event: event, data: data.toString());
  }
}

/// Opens [url] as an event stream on its own HTTP client, so cancelling the
/// subscription closes the connection.
Stream<SseFrame> openSse(Uri url, {String? lastEventId, http.Client Function()? client}) {
  late StreamController<SseFrame> out;
  http.Client? c;
  StreamSubscription<SseFrame>? sub;
  out = StreamController<SseFrame>(
    onListen: () async {
      c = (client ?? http.Client.new)();
      try {
        final req = http.Request('GET', url)
          ..headers['accept'] = 'text/event-stream'
          ..headers['cache-control'] = 'no-cache';
        if (lastEventId != null) req.headers['last-event-id'] = lastEventId;
        // Long enough for RoutedClient to give up on the direct route and open the SSH tunnel (~25 s).
        final res = await c!.send(req).timeout(const Duration(seconds: 30));
        if (res.statusCode >= 400) {
          out.addError(http.ClientException('Event stream returned ${res.statusCode}', url));
          await out.close();
          return;
        }
        sub = res.stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .transform(const SseParser())
            .listen(out.add, onError: out.addError, onDone: out.close);
      } catch (e) {
        if (!out.isClosed) {
          out.addError(e);
          await out.close();
        }
      }
    },
    onCancel: () async {
      await sub?.cancel();
      c?.close();
    },
  );
  return out.stream;
}
