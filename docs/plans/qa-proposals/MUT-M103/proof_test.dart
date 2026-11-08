// Proof for mutant M103: the loopback relay rejects EVENTs with a bad signature.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  test('relay answers OK=false to a forged event', () async {
    final relay = LoopbackNostrRelay();
    await relay.start();
    final ws = await WebSocket.connect(relay.url.toString());
    final ev = NostrEvent.createAndSign(
        sk: BigInt.from(0x1234567), kind: 1, tags: const [], content: 'x', createdAt: 1700000000);
    final forged = NostrEvent(
        id: ev.id, pubkey: ev.pubkey, createdAt: ev.createdAt, kind: ev.kind,
        tags: ev.tags, content: ev.content, sig: '0' * 128);
    final reply = Completer<List<dynamic>>();
    ws.listen((m) { if (!reply.isCompleted) reply.complete(jsonDecode(m as String) as List<dynamic>); });
    ws.add(jsonEncode(['EVENT', forged.toJson()]));
    final r = await reply.future.timeout(const Duration(seconds: 10));
    expect(r[0], 'OK');
    expect(r[2], isFalse);
    await ws.close();
    await relay.stop();
  });
}
