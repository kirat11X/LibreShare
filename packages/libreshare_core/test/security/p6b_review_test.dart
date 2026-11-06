// P6b - adversarial review by the verifying tester (2026-11-05). Added AFTER the coder's work; the
// existing P6b tests are untouched. Tests whose name starts with RED fail against the code as
// reviewed and are what the P6b coder must make green; the others are guards for mutations the
// earlier tests did not catch.
//
// Spec: LSP-1 0.3 ("redirects are never followed", no plain HTTP from a secure client), 4.2
// rules 7, 9, 10, 5.4; docs/plans/inc3-seams.md data-flow 7.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p5_raw_peer.dart';
import '../helpers/p6b_support.dart';
import '../helpers/p6b_tls_peer.dart';

class _Ifaces implements NetworkInterfaceProvider {
  @override
  Future<List<LocalInterface>> list() async => [
    LocalInterface(
      name: 'lo9',
      address: InternetAddress('127.0.0.9'),
      kind: 'unknown',
    ),
  ];
}

class _Sink implements PeerSink {
  final List<(DeviceInfo, String, DiscoverySource)> seen_ = [];
  @override
  void seen(DeviceInfo info, String address, DiscoverySource source) =>
      seen_.add((info, address, source));
}

void main() {
  late P6bPeer alice;
  late P6bPeer impostor;
  late P6bPeer me;
  late P6bPeer server;

  setUpAll(() {
    alice = P6bPeer('p6r-alice');
    impostor = P6bPeer('p6r-impostor');
    me = P6bPeer('p6r-me');
    server = P6bPeer('p6r-server');
  });

  group('secure subnet scan never follows a redirect', () {
    SubnetScanner scannerFor(int port, _Sink sink, {InfoProbe? probe}) =>
        SubnetScanner(
          ifaces: _Ifaces(),
          sink: sink,
          port: port,
          allowLoopback: true,
          maxProbes: 2,
          timeout: const Duration(seconds: 2),
          probe: probe,
          security: SecurityConfig.tls(
            identity: me.key,
            trust: InMemoryTrustStore(),
          ),
        );

    // [RED] _secureInfoProbe uses HttpClient.getUrl without followRedirects = false, so a
    // listener on the scanned port that answers 302 Location: http://... sends the secure
    // probe to a plain-HTTP URL (no certificate involved) and, because `presented` still holds
    // the first host's certificate, a plain server that repeats that fingerprint is accepted.
    // LSP-1 0.3: "redirects are never followed", "a secure client never opens a plain-HTTP
    // connection by itself".
    test(
      'RED a redirect to http:// is not followed by the secure probe',
      () async {
        final plain = await LoopbackPeer.plain(
          server,
          infoFingerprint: server.fp,
        );
        addTearDown(plain.close);
        final redirecting = await RawTlsPeer.start(
          server.key,
          handler: (r) => RawResponse(
            302,
            headers: {'location': 'http://127.0.0.1:${plain.port}/api/v1/info'},
          ),
        );
        addTearDown(redirecting.close);
        final sink = _Sink();
        final result = await scannerFor(redirecting.port, sink).scan();
        expect(
          plain.requests,
          isEmpty,
          reason: 'a plain-HTTP connection was made',
        );
        expect(sink.seen_, isEmpty);
        expect(result.found, isEmpty);
      },
    );

    test(
      'RED a redirect to another https host is not followed either',
      () async {
        final target = await LoopbackPeer.tls(impostor);
        addTearDown(target.close);
        final redirecting = await RawTlsPeer.start(
          server.key,
          handler: (r) => RawResponse(
            307,
            headers: {
              'location': 'https://127.0.0.1:${target.port}/api/v1/info',
            },
          ),
        );
        addTearDown(redirecting.close);
        final sink = _Sink();
        await scannerFor(redirecting.port, sink).scan();
        expect(target.requests, isEmpty, reason: 'the redirect was followed');
        expect(sink.seen_, isEmpty);
      },
    );

    test(
      'control: without the redirect the same harness finds the peer',
      () async {
        final peer = await LoopbackPeer.tls(server);
        addTearDown(peer.close);
        final sink = _Sink();
        final result = await scannerFor(peer.port, sink).scan();
        expect(result.found, hasLength(1));
        expect(peer.requests, hasLength(1));
      },
    );

    // Hardening (low): a custom InfoProbe bypasses the fingerprint-equals-certificate check, and
    // DiscoveryConfig.infoProbe reaches it from outside the core. A secure scanner must either
    // refuse such a probe at construction (ArgumentError/StateError) or ignore it; it must never
    // list what the probe says without the check.
    test('RED a secure scanner does not trust a custom InfoProbe', () async {
      final sink = _Sink();
      final lie = DeviceInfo(
        deviceId: 'p6r-liar',
        alias: 'liar',
        platform: 'linux',
        fingerprint: 'AB' * 32,
        port: 53318,
        version: kProtocolVersionSecure,
      );
      SubnetScanner? scanner;
      try {
        scanner = scannerFor(1, sink, probe: (ip, port, timeout) async => lie);
      } on Object {
        return; // refused at construction: fine
      }
      await scanner.scan();
      expect(sink.seen_, isEmpty);
    });
  });

  group('goodbye while Contacts-only', () {
    // [RED] LSP-1 4.2 rule 10: a Contacts-only receiver "multicasts nothing of its own". The
    // signed bye is a multicast datagram of its own that carries the deviceId and the
    // fingerprint in the clear, so a stranger on the LAN learns that the invisible device exists
    // (and its stable identifier) the moment its Receive mode goes Off. 5.4 promises strangers
    // learn nothing but via an unauthenticated probe claim.
    test('RED a Contacts-only device sends no bye', () async {
      final bus = InMemoryMulticastBus();
      final node = P6bNode(bus, me, contactsOnly: () => true);
      final listener = P6bBare(bus);
      await listener.start();
      await node.discovery.start();
      addTearDown(node.dispose);
      await settle();
      listener.received.clear();

      await node.discovery.sendGoodbye();
      await settle();
      expect(
        listener.received,
        isEmpty,
        reason: 'a bye reveals an invisible device',
      );
    });

    test(
      'control: the same device does send its two byes when it is visible',
      () async {
        final bus = InMemoryMulticastBus();
        final node = P6bNode(bus, me, contactsOnly: () => false);
        final listener = P6bBare(bus);
        await listener.start();
        await node.discovery.start();
        addTearDown(node.dispose);
        await settle();
        listener.received.clear();

        await node.discovery.sendGoodbye();
        await settle();
        expect(
          listener.received.where((p) => decodeBye(p.data) != null),
          hasLength(2),
        );
      },
    );
  });

  group('a pinned device in the registry', () {
    late InMemoryTrustStore trust;
    late PeerRegistry reg;
    final clock = ManualClock();

    setUp(() async {
      trust = InMemoryTrustStore();
      await trust.pin(
        deviceId: alice.id,
        fingerprint: alice.fp,
        alias: 'Alice',
        trust: PeerTrust.known,
      );
      reg = PeerRegistry(selfDeviceId: me.id, clock: clock, trust: trust);
      addTearDown(reg.dispose);
      reg.seen(alice.info(port: 53318), '10.0.0.5', DiscoverySource.multicast);
    });

    // [RED] LSP-1 4.2 rule 7: an announcement with an empty or different fingerprint "never
    // replaces or overrides the pinned device". The registry flags the change but still
    // overwrites the entry (address, port, alias, addrs, and for a different fingerprint the
    // fingerprint itself) with the unauthenticated datagram's content, so one spoofed UDP packet
    // moves a contact to the attacker's address in the device list until the real device
    // announces again (30 s). Pin enforcement at the TLS handshake limits the damage to
    // denial/confusion, not to a key compromise.
    test(
      'RED a different-fingerprint announce keeps the pinned entry as it was',
      () {
        reg.seen(
          alice.info(port: 4444, fingerprint: impostor.fp),
          '10.0.0.66',
          DiscoverySource.multicast,
        );
        final listed = reg.byId(alice.id)!;
        expect(
          reg.fingerprintChanged(alice.id),
          isTrue,
          reason: 'the UI must be able to warn',
        );
        expect(listed.address, '10.0.0.5');
        expect(listed.info.fingerprint, alice.fp);
        expect(listed.info.port, 53318);
      },
    );

    test(
      'RED an empty-fingerprint announce keeps the pinned entry as it was',
      () {
        reg.seen(
          DeviceInfo(
            deviceId: alice.id,
            alias: 'Alice (spoof)',
            platform: 'linux',
            port: 4444,
          ),
          '10.0.0.66',
          DiscoverySource.multicast,
        );
        final listed = reg.byId(alice.id)!;
        expect(listed.address, '10.0.0.5');
        expect(listed.info.alias, isNot('Alice (spoof)'));
        expect(listed.info.port, 53318);
        expect(reg.fingerprintChanged(alice.id), isFalse);
      },
    );

    test(
      'control: the genuine device may move (new address, same fingerprint)',
      () {
        reg.seen(
          alice.info(port: 53320),
          '10.0.0.7',
          DiscoverySource.multicast,
        );
        expect(reg.byId(alice.id)!.address, '10.0.0.7');
        expect(reg.byId(alice.id)!.info.port, 53320);
      },
    );
  });

  group('table pressure', () {
    // Hardening (low): manual and QR peers are exempt from the 90 s sweep but not from the
    // least-recently-seen eviction, and they are never refreshed, so they are the first to go
    // when spoofed announcements fill the table (maxPeers). A sweepable peer should be evicted
    // before one the user added by hand.
    test(
      'RED a flood of multicast peers does not evict a manually added peer',
      () {
        final clock = ManualClock();
        final reg = PeerRegistry(
          selfDeviceId: me.id,
          clock: clock,
          maxPeers: 3,
        );
        addTearDown(reg.dispose);
        reg.seen(alice.info(), '10.0.0.5', DiscoverySource.manual);
        for (var i = 0; i < 6; i++) {
          clock.advance(const Duration(seconds: 1));
          reg.seen(
            DeviceInfo(
              deviceId: 'flood-$i',
              alias: 'f$i',
              platform: 'linux',
              port: 53318,
            ),
            '10.0.1.$i',
            DiscoverySource.multicast,
          );
        }
        expect(reg.byId(alice.id), isNotNull);
        expect(reg.current.length, lessThanOrEqualTo(3));
      },
    );
  });

  group('bye', () {
    late InMemoryMulticastBus bus;
    late ManualClock clock;
    setUp(() {
      bus = InMemoryMulticastBus();
      clock = ManualClock();
    });

    // Guard: a forged bye with a valid ts must not poison the replay memory, so the genuine bye
    // of the same second (higher or equal ts) still works.
    test('forged byes do not block the genuine one afterwards', () async {
      final node = P6bNode(bus, me, clock: clock);
      await node.discovery.start();
      addTearDown(node.dispose);
      node.listPeer(alice);
      node.registry.learnCertificate(alice.certDer);
      final now = tsOf(clock.now());
      // Forged: right shape, window, listed device and known certificate, wrong signature.
      node.hear(rawBye(alice, ts: now + 5000, signer: impostor));
      node.hear(rawBye(alice, ts: now + 5000, signer: impostor));
      await settle();
      expect(node.registry.byId(alice.id), isNotNull);
      await clock.advance(const Duration(seconds: 2));
      node.hear(rawBye(alice, ts: tsOf(clock.now())));
      await settle();
      expect(node.registry.byId(alice.id), isNull);
    });

    // Guard: a bye never removes a device that is not the signer (cross-device) even when the
    // signer is a known peer with a learned certificate.
    test('a valid bye of B cannot remove A', () async {
      final node = P6bNode(bus, me, clock: clock);
      await node.discovery.start();
      addTearDown(node.dispose);
      node.listPeer(alice);
      node.listPeer(impostor);
      node.registry.learnCertificate(alice.certDer);
      node.registry.learnCertificate(impostor.certDer);
      final now = tsOf(clock.now());
      node.hear(rawBye(impostor, ts: now, deviceId: alice.id));
      node.hear(
        rawBye(impostor, ts: now, deviceId: alice.id, fingerprint: alice.fp),
      );
      await settle();
      expect(node.listed, [alice.id, impostor.id]..sort());
    });

    // Guard: 200 forged byes in one second cannot grow any memory or remove anybody, and a
    // fresh budget second lets the genuine bye through.
    test('a burst of forged byes is bounded and the budget recovers', () async {
      final node = P6bNode(bus, me, clock: clock);
      await node.discovery.start();
      addTearDown(node.dispose);
      node.listPeer(alice);
      node.registry.learnCertificate(alice.certDer);
      final now = tsOf(clock.now());
      for (var i = 0; i < 200; i++) {
        node.hear(
          rawBye(alice, ts: now + 1 + i, signer: impostor),
          from: '10.0.${i % 200}.1',
        );
      }
      node.hear(rawBye(alice, ts: now + 500));
      await settle();
      expect(
        node.registry.byId(alice.id),
        isNotNull,
        reason: 'budget exhausted: dropped unverified',
      );
      await clock.advance(const Duration(seconds: 2));
      node.hear(rawBye(alice, ts: tsOf(clock.now()) + 1000));
      await settle();
      expect(node.registry.byId(alice.id), isNull);
    });
  });

  group('typed data', () {
    test(
      'learnCertificate rejects a certificate with a broken self-signature',
      () {
        final reg = PeerRegistry(selfDeviceId: me.id);
        addTearDown(reg.dispose);
        final der = Uint8List.fromList(alice.certDer);
        der[der.length - 3] ^= 0x01; // inside the signature value
        expect(reg.learnCertificate(der), isFalse);
        expect(reg.certificateFor(alice.fp), isNull);
      },
    );
  });

  group('Contacts-only callback that throws', () {
    // Guard (mutation gap): a failing visibility callback must keep the device invisible.
    test(
      'fails closed: no announce and no answer to a stranger probe',
      () async {
        final bus = InMemoryMulticastBus();
        final node = P6bNode(
          bus,
          me,
          probes: true,
          contactsOnly: () => throw StateError('visibility store not loaded'),
        );
        final listener = P6bBare(bus);
        await listener.start();
        await node.discovery.start();
        addTearDown(node.dispose);
        await settle();

        node.discovery.announceNow();
        listener.announce(alice.info(port: 0), probe: true);
        listener.announce(alice.info());
        await settle();
        expect(
          listener.announces.where((m) => m.info.deviceId == me.id),
          isEmpty,
          reason: 'the device must stay silent (the bus echoes the listener own datagrams)',
        );
        expect(node.discovery.announcesSent, 0);
        expect(node.discovery.repliesSent, 0);
      },
    );
  });
}
