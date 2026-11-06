// P6b - the goodbye datagram end to end over the in-memory bus (no engine):
// a device that says goodbye is gone from the other list in <= 1 s instead of
// <= 90 s. The two-engine variant (`integration/goodbye_engine_test`) belongs
// to P6a.
//
// Spec: LSP-1 4.2 rules 8 and 9, docs/plans/inc3.md section 10 item 1
// (acceptance "gone from the other list in <= 1 s"), D12 and the traceability
// row "Receive Off removes the device from the other list in <= 1 s".
//
// The observer learns the leaving device's certificate the way the real system
// does: through the registrar (a TLS handshake when it answers the announce).
// Here the registrar is a stand-in that hands the certificate to the registry.
import 'dart:async';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:test/test.dart';

import '../helpers/p6b_support.dart';

void main() {
  late P6bPeer leaving;
  late P6bPeer obsB;
  late P6bPeer obsC;
  late P6bPeer obsD;

  setUpAll(() {
    leaving = P6bPeer('gone-0000');
    obsB = P6bPeer('obs-b');
    obsC = P6bPeer('obs-c');
    obsD = P6bPeer('obs-d');
  });

  late InMemoryMulticastBus bus;
  late P6bNode a; // the device that goes Off
  late P6bNode b; // observer that learns A's certificate
  late P6bNode c; // observer that never completes a handshake with A
  late P6bNode d; // observer in the plaintext profile
  late List<DiscoveryEvent> bEvents;
  var handshakes = 0; // times B's registrar learned A's certificate

  setUp(() async {
    bus = InMemoryMulticastBus();
    handshakes = 0;
    final certs = <String, Uint8List>{leaving.fp: leaving.certDer};
    a = P6bNode(bus, leaving);
    b = P6bNode(
      bus,
      obsB,
      registrar: (peer, address) async {
        final cert = certs[peer.fingerprint];
        final ok = cert != null && b.registry.learnCertificate(cert);
        if (ok) handshakes++;
        return ok;
      },
    );
    c = P6bNode(bus, obsC, registrar: (peer, address) async => false);
    d = P6bNode(bus, obsD, secure: false);
    bEvents = [];
    b.registry.events.listen(bEvents.add);
    // The observers are up before A announces for the first time, so each of
    // them meets A through its announce (and registers) rather than through a
    // UDP reply.
    for (final n in [b, c, d, a]) {
      await n.discovery.start();
    }
    await settle();
  });

  tearDown(() async {
    for (final n in [a, b, c, d]) {
      await n.dispose();
    }
  });

  Future<void> announceAndWait() async {
    a.discovery.announceNow();
    await eventually(
      () => [b, c, d].every((o) => o.registry.byId(leaving.id) != null),
      what: 'observers list the device',
    );
  }

  test('receive_off_removes_device_from_the_other_list_within_1s', () async {
    await announceAndWait();
    await eventually(() => handshakes >= 1, what: 'observer learned the cert');
    bEvents.clear();

    final sw = Stopwatch()..start();
    unawaited(a.discovery.sendGoodbye());
    await eventually(
      () => b.registry.byId(leaving.id) == null,
      timeout: const Duration(seconds: 1),
      what: 'device removed',
    );
    sw.stop();

    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    await settle();
    expect(bEvents.whereType<DeviceLost>().map((e) => e.device.id), [
      leaving.id,
    ], reason: 'once, although the bye is sent twice');
  });

  test('only observers that can verify it drop the device', () async {
    await announceAndWait();
    await eventually(() => handshakes >= 1, what: 'observer learned the cert');

    await a.discovery.sendGoodbye();
    await settle();

    expect(b.registry.byId(leaving.id), isNull);
    expect(
      c.registry.byId(leaving.id),
      isNotNull,
      reason: 'no certificate: expires after 90 s as before',
    );
    expect(
      d.registry.byId(leaving.id),
      isNotNull,
      reason: 'plaintext receivers drop the datagram',
    );
  });

  test('stop() after the goodbye keeps the device gone; announcing again '
      'brings it back, and a later goodbye works again', () async {
    await announceAndWait();
    await eventually(() => handshakes >= 1, what: 'observer learned the cert');

    await a.discovery.sendGoodbye();
    await a.discovery.stop();
    await settle();
    expect(b.registry.byId(leaving.id), isNull);

    // Receive On again: the same device announces, the observer re-registers.
    await a.discovery.start();
    a.discovery.announceNow();
    await eventually(
      () => handshakes >= 2,
      what: 'device is back, re-registered',
    );
    expect(b.registry.byId(leaving.id), isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // The earlier bye must neither block the announce nor the next bye.
    await a.discovery.sendGoodbye();
    await eventually(
      () => b.registry.byId(leaving.id) == null,
      timeout: const Duration(seconds: 1),
      what: 'second removal',
    );
  });

  test('a bye is never answered by any observer', () async {
    await announceAndWait();
    await settle();
    final before = bus.unicasts.length;
    await a.discovery.sendGoodbye();
    await settle();
    expect(c.registry.byId(leaving.id), isNotNull);
    expect(
      bus.unicasts.length,
      before,
      reason: 'a bye is never answered by any observer',
    );
  });
}
