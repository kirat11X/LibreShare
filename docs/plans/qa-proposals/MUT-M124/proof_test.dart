// STATUS: NOT A PROOF. Green on pristine AND on the mutant: the model parser rejects a non-string "v" too (redundant guard), so M124 is an equivalent mutant.
// Proof for mutant M124: a non-string protocol "v" is a 400, not silently coerced.
// Install as packages/libreshare_core/test/<name>.dart (uses test/helpers).
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import 'helpers/api_fake_handler.dart';

void main() {
  test('numeric "v" -> 400 BAD_REQUEST', () async {
    final fake = FakeIncomingHandler();
    final server = ApiServer(
      handler: fake,
      bindAddress: InternetAddress.loopbackIPv4,
      preferredPort: 0,
      enableRateLimit: false,
    );
    final port = await server.start();
    addTearDown(() => server.stop(force: true));
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    Future<int> reg(Object v) async {
      final body = sampleRequest().sender.toJson()..['v'] = v;
      final req = await http.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:$port$kApiPrefix/register'),
      );
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length;
      req.add(bytes);
      final r = await req.close();
      await r.drain<void>();
      return r.statusCode;
    }

    expect(await reg(1), 400);
    expect(await reg('2.0'), 426, reason: 'positive control');
  });
}
