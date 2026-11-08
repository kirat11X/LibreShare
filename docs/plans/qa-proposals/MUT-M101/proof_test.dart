// Proof for mutant M101: rendezvous envelope nonce is random per seal.
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  test('two seals of one record differ in nonce and ciphertext', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
    const rec = ProbeRecord(seq: 1, issuedAt: 1000, nonce: 'abc');
    const codec = EnvelopeCodecImpl();
    final a = codec.seal(record: rec, envelopeKey: key, channelIdHex: 'ch');
    final b = codec.seal(record: rec, envelopeKey: key, channelIdHex: 'ch');
    expect(a.sublist(0, kRendezvousNonceBytes), isNot(b.sublist(0, kRendezvousNonceBytes)));
    expect(a, isNot(b));
  });
}
