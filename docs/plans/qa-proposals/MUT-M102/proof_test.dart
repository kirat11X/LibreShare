// Proof for mutant M102: a record that exactly fills a bucket uses that bucket (not the next).
import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  test('exact-fit record is sealed into the 512 bucket', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
    const codec = EnvelopeCodecImpl();
    ProbeRecord? exact;
    for (var len = 1; len < 600; len++) {
      final r = ProbeRecord(seq: 1, issuedAt: 1000, nonce: 'a' * len);
      if (2 + utf8.encode(jsonEncode(r.toJson())).length == 512) { exact = r; break; }
    }
    expect(exact, isNotNull);
    final sealed = codec.seal(record: exact!, envelopeKey: key, channelIdHex: 'ch');
    expect(sealed.length, 512 + kRendezvousOverheadBytes);
  });
}
