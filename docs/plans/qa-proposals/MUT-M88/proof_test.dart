// Proof for mutant M88: a Nostr event whose sig/pubkey carry trailing bytes must not verify.
import 'package:libreshare_core/src/rendezvous/nip01.dart';
import 'package:test/test.dart';

void main() {
  final ev = NostrEvent.createAndSign(
      sk: BigInt.from(0x1234567), kind: 1, tags: const [], content: 'x', createdAt: 1700000000);
  NostrEvent with_({String? sig, String? pubkey}) => NostrEvent(
      id: ev.id, pubkey: pubkey ?? ev.pubkey, createdAt: ev.createdAt, kind: ev.kind,
      tags: ev.tags, content: ev.content, sig: sig ?? ev.sig);
  test('valid event verifies (positive control)', () => expect(ev.verify(), isTrue));
  test('sig with trailing junk is rejected', () {
    expect(with_(sig: '${ev.sig}aa').verify(), isFalse);
  });
}
