// P6b - the subnet scan in the secure profile: HTTPS probes, and a peer is
// accepted only if its /info fingerprint equals the SHA-256 of the certificate
// it presented in that very handshake.
//
// Spec: docs/plans/inc3-seams.md data-flow item 7, docs/plans/inc3.md section
// 10 item 3 ("the scan moves to HTTPS with the fingerprint-equals-certificate
// check") and `security/pinning_test` `fingerprint_in_info_must_equal_certificate_hash`,
// LSP-1 0.3 ("a secure client never opens a plain-HTTP connection"), 4.2 rule 4,
// 4.3.6 (GET /info carries X-LS-Auth only towards a pinned, Contacts-only peer:
// an unauthenticated server is never offered our identity).
//
// New symbols under test (all optional/named, defaults keep Inc 2 behaviour):
//   SubnetScanner(security: SecurityConfig, onCertificate: void Function(Uint8List)?)
//   ScanResult.rejected  // int, hosts that answered but were refused
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/security/crypto_primitives.dart'
    show sha256Hex;
import 'package:test/test.dart';

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
  late P6bPeer server; // the peer being scanned
  late P6bPeer other; // some other real identity
  late P6bPeer scanner;
  late _Sink sink;
  late List<Uint8List> certs;
  final open = <LoopbackPeer>[];

  setUpAll(() {
    server = P6bPeer('scan-server');
    other = P6bPeer('scan-other');
    scanner = P6bPeer('scan-client');
  });

  setUp(() {
    sink = _Sink();
    certs = [];
  });

  tearDown(() async {
    for (final p in open) {
      await p.close();
    }
    open.clear();
  });

  Future<LoopbackPeer> tlsPeer({String? infoFingerprint}) async {
    final p = await LoopbackPeer.tls(server, infoFingerprint: infoFingerprint);
    open.add(p);
    return p;
  }

  Future<LoopbackPeer> plainPeer({String? infoFingerprint}) async {
    final p = await LoopbackPeer.plain(
      server,
      infoFingerprint: infoFingerprint,
    );
    open.add(p);
    return p;
  }

  /// Sweeps 127.0.0.1-127.0.0.2 (own address 127.0.0.9 is excluded) on [port].
  SubnetScanner scannerFor(int port, {required bool secure}) => SubnetScanner(
    ifaces: _Ifaces(),
    sink: sink,
    port: port,
    allowLoopback: true,
    maxProbes: 2,
    timeout: const Duration(seconds: 2),
    security: secure
        ? SecurityConfig.tls(identity: scanner.key, trust: InMemoryTrustStore())
        : const SecurityConfig.plaintext(),
    onCertificate: certs.add,
  );

  group('secure profile', () {
    test(
      'a peer whose /info fingerprint equals its certificate is found',
      () async {
        final peer = await tlsPeer();
        final result = await scannerFor(peer.port, secure: true).scan();

        expect(result.found, hasLength(1));
        expect(result.rejected, 0);
        expect(sink.seen_, hasLength(1));
        final (info, address, source) = sink.seen_.single;
        expect(info.deviceId, server.id);
        expect(info.fingerprint, server.fp);
        expect(address, '127.0.0.1');
        expect(source, DiscoverySource.subnetScan);
        expect(peer.requests, hasLength(1));
        expect(peer.requests.single.method, 'GET');
        expect(peer.requests.single.path, '/api/v1/info');
      },
    );

    test('the certificate seen in the handshake is handed over (so a later bye '
        'can be verified)', () async {
      final peer = await tlsPeer();
      await scannerFor(peer.port, secure: true).scan();
      expect(certs, hasLength(1));
      expect(sha256Hex(certs.single).toUpperCase(), server.fp);
      expect(certs.single, server.certDer);
    });

    test('fingerprint_in_info_must_equal_certificate_hash: a lying /info is '
        'rejected and counted', () async {
      // Presents server's certificate but claims another device's fingerprint
      // (a relay that copied somebody else's /info would look like this).
      final peer = await tlsPeer(infoFingerprint: other.fp);
      final result = await scannerFor(peer.port, secure: true).scan();

      expect(result.found, isEmpty);
      expect(sink.seen_, isEmpty);
      expect(result.rejected, 1);
      expect(certs, isEmpty, reason: 'an unverified certificate is not kept');
      expect(peer.requests, hasLength(1), reason: 'the probe did happen');
    });

    test('an /info with an empty fingerprint over TLS is rejected', () async {
      final peer = await tlsPeer(infoFingerprint: '');
      final result = await scannerFor(peer.port, secure: true).scan();
      expect(result.found, isEmpty);
      expect(sink.seen_, isEmpty);
      expect(result.rejected, 1);
    });

    test('plaintext_server_refused: no plain HTTP is ever attempted', () async {
      final peer = await plainPeer(infoFingerprint: server.fp);
      final result = await scannerFor(peer.port, secure: true).scan();

      expect(result.found, isEmpty);
      expect(sink.seen_, isEmpty);
      expect(peer.requests, isEmpty, reason: 'zero parsed HTTP requests');
      expect(certs, isEmpty);
    });

    test('GET /info does not offer our identity (no X-LS-Auth) to a server we '
        'have not pinned', () async {
      final peer = await tlsPeer();
      await scannerFor(peer.port, secure: true).scan();
      expect(peer.requests, isNotEmpty);
      for (final r in peer.requests) {
        expect(r.headers.containsKey('x-ls-auth'), isFalse);
      }
    });

    test(
      'nothing listening: no result, no exception, nothing rejected',
      () async {
        final peer = await tlsPeer();
        final port = peer.port;
        await peer.close();
        open.clear();
        final result = await scannerFor(port, secure: true).scan();
        expect(result.found, isEmpty);
        expect(result.rejected, 0);
      },
    );
  });

  group('plaintext profile is unchanged', () {
    test(
      'a plaintext peer is found over plain HTTP, rejected stays 0',
      () async {
        final peer = await plainPeer();
        final result = await scannerFor(peer.port, secure: false).scan();
        expect(result.found, hasLength(1));
        expect(result.rejected, 0);
        expect(sink.seen_.single.$1.deviceId, server.id);
        expect(sink.seen_.single.$1.fingerprint, isEmpty);
        expect(peer.requests.single.path, '/api/v1/info');
        expect(peer.requests.single.headers.containsKey('x-ls-auth'), isFalse);
      },
    );

    test('a TLS-only peer is not reachable over plain HTTP (positive twin of '
        'the secure test above: the harness sees TLS peers)', () async {
      final peer = await tlsPeer();
      final result = await scannerFor(peer.port, secure: false).scan();
      expect(result.found, isEmpty);
      expect(peer.requests, isEmpty);
    });

    test('no fingerprint-equals-certificate check without TLS: a plaintext '
        'peer claiming a fingerprint is listed as announced', () async {
      final peer = await plainPeer(infoFingerprint: other.fp);
      final result = await scannerFor(peer.port, secure: false).scan();
      expect(result.found, hasLength(1));
      expect(sink.seen_.single.$1.fingerprint, other.fp);
    });
  });
}
