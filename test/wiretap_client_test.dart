import 'package:borealis/borealis.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_rig/api/wiretap_client.dart';

void main() {
  setUp(WiretapStore.instance.clear);

  test('records request and decoded JSON response', () async {
    final c = WiretapClient(MockClient((req) async => http.Response('{"ok":true}', 200)));
    final res = await c.post(Uri.parse('http://h/api/x'), body: '{"a":1}');
    expect(res.body, '{"ok":true}');
    final e = WiretapStore.instance.entries.single;
    expect(e.method, 'POST');
    expect(e.requestBody, {'a': 1});
    expect(e.statusCode, 200);
    expect(e.responseBody, {'ok': true});
    expect(e.isLoading, isFalse);
  });

  test('records a failed request and rethrows', () async {
    final c = WiretapClient(MockClient((req) async => throw http.ClientException('down')));
    await expectLater(c.get(Uri.parse('http://h/api/y')), throwsA(isA<http.ClientException>()));
    final e = WiretapStore.instance.entries.single;
    expect(e.error, isA<http.ClientException>());
    expect(e.isLoading, isFalse);
  });

  test('event streams complete once headers arrive', () async {
    final c = WiretapClient(MockClient.streaming((req, body) async =>
        http.StreamedResponse(const Stream.empty(), 200, headers: {'content-type': 'text/event-stream'})));
    await c.send(http.Request('GET', Uri.parse('http://h/api/events')));
    expect(WiretapStore.instance.entries.single.responseBody, '<event stream>');
  });

  test('an app credential never reaches the inspector: the bearer header and the credentials response are redacted', () async {
    final c = WiretapClient(MockClient((req) async => http.Response('{"token":"orapp_secret","credentialId":"c"}', 201)));
    await c.post(Uri.parse('http://h/api/apps/v1/credentials'), headers: {'Authorization': 'Bearer orapp_secret'}, body: '{}');
    await c.get(Uri.parse('http://h/api/apps/v1/needs-me'), headers: {'authorization': 'Bearer orapp_secret'});
    for (final e in WiretapStore.instance.entries) {
      expect(e.requestHeaders.values, isNot(contains(contains('orapp_secret'))));
    }
    expect(WiretapStore.instance.entries.first.responseBody.toString(), isNot(contains('orapp_secret')));
  });
}
