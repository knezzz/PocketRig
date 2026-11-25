import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/chat/transcript.dart';

void main() {
  String line(String uuid, String msgId, Map<String, int> usage, String text) => jsonEncode({
        'uuid': uuid,
        'type': 'assistant',
        'timestamp': '2026-11-05T10:00:00Z',
        'message': {
          'id': msgId,
          'model': 'claude-opus-5-5',
          'usage': usage,
          'content': [
            {'type': 'text', 'text': text}
          ],
        },
      });

  test('context is the newest turn; output is summed once per message', () {
    final t = ChatTranscript()
      ..add(line('a', 'm1', {'input_tokens': 10, 'cache_read_input_tokens': 1000, 'output_tokens': 50}, 'one'))
      // The same message logged again for its next block: its usage isn't counted twice.
      ..add(line('b', 'm1', {'input_tokens': 10, 'cache_read_input_tokens': 1000, 'output_tokens': 50}, 'two'))
      ..add(line('c', 'm2', {'input_tokens': 5, 'cache_read_input_tokens': 2000, 'cache_creation_input_tokens': 100, 'output_tokens': 20}, 'three'));
    expect(t.contextTokens, 2105);
    expect(t.outputTokens, 70);
  });

  test('the phone cache keeps usage', () {
    final slim = slimLogLine(line('a', 'm1', {'input_tokens': 10, 'output_tokens': 50, 'service_tier': 1}, 'x'));
    final t = ChatTranscript()..add(slim);
    expect(t.contextTokens, 10);
    expect(t.outputTokens, 50);
    expect(slim, isNot(contains('service_tier')));
  });
}
