// Proof for mutant M89: Nostr event verify() must check the BIP-340 signature.
import 'package:libreshare_core/src/rendezvous/nip01.dart';
import 'package:test/test.dart';

void main() {
  final ev = NostrEvent.createAndSign(
      sk: BigInt.from(0x1234567), kind: 1, tags: const [], content: 'x', createdAt: 1700000000);
  test('valid event verifies (positive control)', () => expect(ev.verify(), isTrue));
  test('event with a forged signature (id intact) is rejected', () {
    final flipped = ev.sig.substring(0, 127) + (ev.sig[127] == '0' ? '1' : '0');
    final forged = NostrEvent(
        id: ev.id, pubkey: ev.pubkey, createdAt: ev.createdAt, kind: ev.kind,
        tags: ev.tags, content: ev.content, sig: flipped);
    expect(forged.verify(), isFalse);
    final zeros = NostrEvent(
        id: ev.id, pubkey: ev.pubkey, createdAt: ev.createdAt, kind: ev.kind,
        tags: ev.tags, content: ev.content, sig: '0' * 128);
    expect(zeros.verify(), isFalse);
  });
}
