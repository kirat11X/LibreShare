// Q-CLI-DISCOVERY fix2: a send-only probe is also sent from a socket with its
// own ephemeral source port, so the unicast reply (LSP-1 4.2 rule 8: to the
// probe's source address and port) reaches the prober even when the replier
// and the prober share the discovery port on one host (SO_REUSEPORT delivers a
// datagram for that port to one of the bound sockets, often the replier's own).
//
// Real sockets on a non-production port. Skips itself where the host does not
// deliver multicast.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:libreshare_core/src/discovery/multicast_discovery.dart';
import 'package:libreshare_core/src/discovery/multicast_transport.dart';
import 'package:libreshare_core/src/discovery/peer_registry.dart';
import 'package:libreshare_core/src/model/device.dart';
import 'package:test/test.dart';

const int _port = 53395;
String? _skip;

void main() {
  setUpAll(() async {
    final a = RawMulticastTransport(port: _port);
    final b = RawMulticastTransport(port: _port);
    try {
      await a.start();
      await b.start();
      final got = Completer<void>();
      final sub = b.packets.listen((p) {
        if (utf8.decode(p.data, allowMalformed: true) == 'q') {
          if (!got.isCompleted) got.complete();
        }
      });
      final t = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => a.sendMulticast(utf8.encode('q')),
      );
      try {
        await got.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        _skip = 'UDP multicast is not delivered on this host';
      } finally {
        t.cancel();
        await sub.cancel();
      }
    } on Object catch (e) {
      _skip = 'cannot open/join the multicast socket on UDP $_port: $e';
    } finally {
      await a.stop();
      await b.stop();
    }
  });

  test('GUARD probe-ephemeral-source: a quiet receiver on the same port and host answers a probe by unicast and the prober hears it', () async {
    if (_skip != null) {
      markTestSkipped(_skip!);
      return;
    }
    final rxReg = PeerRegistry(selfDeviceId: 'pe-rx');
    final txReg = PeerRegistry(selfDeviceId: 'pe-tx');
    final rx = MulticastDiscovery(
      selfInfo: () => const DeviceInfo(
        deviceId: 'pe-rx',
        alias: 'pe-receiver',
        platform: 'linux',
        port: 53396,
      ),
      transport: RawMulticastTransport(port: _port),
      registry: rxReg,
      probes: true,
      announceSchedule: const [],
      periodicInterval: const Duration(hours: 1),
    );
    final tx = MulticastDiscovery(
      selfInfo: () => const DeviceInfo(
        deviceId: 'pe-tx',
        alias: 'pe-prober',
        platform: 'linux',
        port: 0,
      ),
      transport: RawMulticastTransport(port: _port),
      registry: txReg,
      probes: true,
      announceSchedule: const [],
      periodicInterval: const Duration(hours: 1),
    );
    addTearDown(() async {
      await rx.stop();
      await tx.stop();
      rxReg.dispose();
      txReg.dispose();
    });
    await rx.start();
    // The receiver's start announcement is over before the prober exists.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tx.start();
    final sw = Stopwatch()..start();
    while (txReg.byId('pe-rx') == null &&
        sw.elapsed < const Duration(seconds: 3)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      txReg.byId('pe-rx'),
      isNotNull,
      reason: 'the unicast reply to the probe reached the prober',
    );
    expect(rxReg.byId('pe-tx'), isNull, reason: 'a probe is never recorded');
  });

  test('GUARD probe-socket-closed-on-stop: stop() releases the probe socket and a restarted transport probes again', () async {
    if (_skip != null) {
      markTestSkipped(_skip!);
      return;
    }
    final t = RawMulticastTransport(port: _port);
    await t.start();
    t.sendProbeFromEphemeralPort([1]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await t.stop();
    t.sendProbeFromEphemeralPort([1]); // stopped: no-op, no throw
    await t.start();
    t.sendProbeFromEphemeralPort([1]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await t.stop();
  });
}
