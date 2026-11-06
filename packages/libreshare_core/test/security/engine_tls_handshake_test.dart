// P6a - the real engine facade serves TLS 1.3 with the certificate of its persistent identity.
//
// Spec: LSP-1 0.3 (profiles), 4.1 (HTTPS, TLS >= 1.3), 4.7 (a TLS-only listener answers a plaintext
// client by closing the connection), 5 (fingerprint = SHA-256 of the DER certificate); docs/plans/
// inc3.md D1, D8, D10; docs/plans/inc3-seams.md rule 1 (the plaintext profile stays Inc 1/2 byte
// for byte) and 9b item 1 (`--advertise-ip`).
//
// SPEC-GAP: an engine whose `self.deviceId` differs from the identity's device id is refused with
// an ArgumentError at construction (the safer reading: otherwise peers would pin a CN that
// disagrees with the id they are told).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/p6a_support.dart';

/// The certificate the listener presents in a TLS handshake, taken without verifying it.
Future<List<int>> presentedCertificate(String host, int port) async {
  final s = await SecureSocket.connect(
    host,
    port,
    onBadCertificate: (_) => true,
  );
  try {
    return s.peerCertificate!.der;
  } finally {
    s.destroy();
  }
}

Future<Map<String, Object?>> getInfo(
  String host,
  int port, {
  bool tls = true,
}) async {
  final r = await rawGet(host, port, '$kApiPrefix/info', tls: tls);
  expect(r.status, 200, reason: r.body);
  return (jsonDecode(r.body) as Map).cast<String, Object?>();
}

Future<bool> opensslAvailable() async {
  try {
    return (await Process.run('openssl', ['version'])).exitCode == 0;
  } on Object {
    return false;
  }
}

/// Runs `openssl s_client` against the listener (the address the engine really bound) with one TLS
/// version and returns its output.
Future<String> sClient(String host, int port, String versionFlag) async {
  final proc = await Process.start('openssl', [
    's_client',
    '-connect',
    '$host:$port',
    versionFlag,
  ]);
  await proc.stdin.close();
  final out = StringBuffer();
  final sub = proc.stdout.transform(utf8.decoder).listen(out.write);
  final sub2 = proc.stderr.transform(utf8.decoder).listen(out.write);
  try {
    await proc.exitCode.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    proc.kill();
    await proc.exitCode;
  }
  await sub.cancel();
  await sub2.cancel();
  return out.toString();
}

Future<void> main() async {
  final skipAlias = await p6aSkipReason();
  final haveOpenssl = await opensslAvailable();
  late Directory sandbox;
  late P6aRig rig;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ls_p6a_tls_');
    rig = P6aRig(sandbox);
  });
  tearDown(() async {
    await rig.dispose();
    sandbox.deleteSync(recursive: true);
  });

  // LSP-1 0.3 / 4.1: the secure profile is HTTPS with the identity certificate.
  group('the engine listener presents the identity certificate', () {
    test('the handshake certificate hashes to the identity fingerprint, CN is the device id', () async {
      final a = await rig.start('Alice');
      final der = await presentedCertificate(a.ip, a.port);
      final presented = fingerprintHex(der);

      expect(presented, a.fp, reason: 'listener certificate == identity');
      expect(presented, a.engine.identity!.fingerprint);
      expect(presented, a.engine.ownFingerprint);
      expect(presented, matches(RegExp(r'^[0-9A-F]{64}$')));
      expect(parseCertificate(Uint8List.fromList(der)).subjectCn, a.deviceId);
    }, skip: skipAlias);

    test('two engines present two different certificates (the harness can tell identities apart)', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob');
      expect(fingerprintHex(await presentedCertificate(a.ip, a.port)), a.fp);
      expect(fingerprintHex(await presentedCertificate(b.ip, b.port)), b.fp);
      expect(a.fp, isNot(b.fp));
    }, skip: skipAlias);

    test('GET /info over TLS reports version 1.1, the fingerprint of the certificate, caps sas and pair', () async {
      final a = await rig.start('Alice');
      final info = await getInfo(a.ip, a.port);
      expect(info['v'], kProtocolVersionSecure);
      expect(info['v'], '1.1');
      expect(info['deviceId'], a.deviceId);
      expect(info['alias'], 'Alice');
      expect(info['fingerprint'], a.fp);
      expect(info['port'], a.port);
      expect(info['caps'] as List, containsAll(['sas', 'pair']));
      expect(
        info['fingerprint'],
        fingerprintHex(await presentedCertificate(a.ip, a.port)),
        reason:
            'fingerprint in /info must equal the certificate hash (LSP-1 0.2)',
      );
    }, skip: skipAlias);

    test('the engine fills deviceInfo with the identity fingerprint although self had none', () async {
      final a = await rig.start('Alice');
      expect(a.engine.self.fingerprint, isEmpty, reason: 'harness gave none');
      expect(a.engine.deviceInfo.fingerprint, a.fp);
      expect(a.engine.deviceInfo.version, '1.1');
      expect(a.engine.deviceInfo.deviceId, a.deviceId);
    }, skip: skipAlias);

    test(
      'an engine whose self.deviceId is not the identity device id is refused',
      () async {
        final wiring = await SecurityWiring.open(
          directory: Directory(p.join(sandbox.path, 'id-mismatch')),
          deviceId: newDeviceId(),
        );
        addTearDown(wiring.close);
        expect(
          () => LibreShareEngine(
            self: DeviceInfo(
              deviceId: newDeviceId(),
              alias: 'X',
              platform: 'linux',
            ),
            downloadDir: Directory(p.join(sandbox.path, 'rx')),
            security: wiring,
          ),
          throwsArgumentError,
        );
      },
    );
  });

  // LSP-1 4.7: never negotiated down, a TLS-only listener closes a plaintext client.
  group('plaintext clients are refused (no downgrade)', () {
    test('a plaintext HTTP request gets no HTTP bytes back; the same request works on a plaintext engine', () async {
      final secure = await rig.start('Secure');
      final legacy = await rig.start('Legacy', secure: false);

      Future<String> rawPlain(int port, String host) async {
        final s = await Socket.connect(host, port);
        s.write(
          'GET $kApiPrefix/info HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n',
        );
        await s.flush();
        final buf = StringBuffer();
        try {
          await s
              .cast<List<int>>()
              .transform(const Utf8Decoder(allowMalformed: true))
              .forEach(buf.write)
              .timeout(const Duration(seconds: 5));
        } on Object {
          // a reset is as good as a close
        }
        s.destroy();
        return buf.toString();
      }

      expect(
        await rawPlain(legacy.port, legacy.ip),
        startsWith('HTTP/1.1 200'),
        reason: 'twin: the harness sees an answer when there is one',
      );
      final answer = await rawPlain(secure.port, secure.ip);
      expect(answer, isNot(contains('HTTP/')));
      expect(answer, isNot(contains(secure.deviceId)));
      expect(answer.trim(), isEmpty);
    }, skip: skipAlias);

    test('dart:io http:// client against the secure engine fails; against the plaintext engine it works', () async {
      final secure = await rig.start('Secure');
      final legacy = await rig.start('Legacy', secure: false);
      expect(
        (await rawGet(
          legacy.ip,
          legacy.port,
          '$kApiPrefix/info',
          tls: false,
        )).status,
        200,
      );
      await expectLater(
        rawGet(secure.ip, secure.port, '$kApiPrefix/info', tls: false),
        throwsA(anything),
      );
    }, skip: skipAlias);

    test('TLS 1.2 is refused, TLS 1.3 is accepted (openssl)', () async {
      final a = await rig.start('Alice');
      final v12 = await sClient(a.ip, a.port, '-tls1_2');
      final v13 = await sClient(a.ip, a.port, '-tls1_3');
      expect(
        v13,
        contains('BEGIN CERTIFICATE'),
        reason: 'twin: openssl can see the certificate',
      );
      expect(v12, isNot(contains('BEGIN CERTIFICATE')));
      expect(
        v12.toLowerCase(),
        anyOf(contains('alert'), contains('error'), contains('no protocols')),
      );
    }, skip: haveOpenssl ? skipAlias : 'openssl not installed');

    test('the plaintext profile engine is the Inc 1/2 wire: /info v 1.0, empty fingerprint, no identity', () async {
      final legacy = await rig.start('Legacy', secure: false);
      final info = await getInfo(legacy.ip, legacy.port, tls: false);
      expect(info['v'], '1.0');
      expect(info['fingerprint'], '');
      expect((info['caps'] as List), isNot(contains('pair')));
      expect(legacy.engine.identity, isNull);
      expect(legacy.engine.ownFingerprint, '');
      expect(legacy.engine.pinGuard, isNull);
      expect(legacy.engine.currentContacts, isEmpty);
      // The plaintext profile has no /pair route: it falls under the 404 routing rule.
      final r = await rawGet(
        legacy.ip,
        legacy.port,
        '$kApiPrefix/pair',
        tls: false,
      );
      expect(r.status, 404);
    }, skip: skipAlias);
  });

  // Persistent identity: the same certificate across restarts (docs/plans/inc3.md D3).
  group('the identity survives an engine restart', () {
    test('restart with the same identity directory presents the same certificate; a new directory a new one', () async {
      final dir = Directory(p.join(sandbox.path, 'id-keep'));
      final id = newDeviceId();
      final first = await rig.start('Alice', idDir: dir, deviceId: id);
      final fp1 = fingerprintHex(
        await presentedCertificate(first.ip, first.port),
      );
      await rig.stop(first);

      final again = await rig.start('Alice', idDir: dir, deviceId: id);
      expect(
        fingerprintHex(await presentedCertificate(again.ip, again.port)),
        fp1,
      );
      expect(again.deviceId, id);
      await rig.stop(again);

      final fresh = await rig.start(
        'Alice',
        idDir: Directory(p.join(sandbox.path, 'id-new')),
        deviceId: id,
      );
      expect(
        fingerprintHex(await presentedCertificate(fresh.ip, fresh.port)),
        isNot(fp1),
        reason: 'a new identity directory is a new key (twin of the persistence check)',
      );
    }, skip: skipAlias);
  });

  // docs/plans/inc3.md section 9b item 1: what other devices learn about our address.
  group('--advertise-ip: the address others are told', () {
    test('/info addrs, deviceInfo, the peer link and the pair invite carry the advertised address', () async {
      final a = await rig.start('Alice', advertiseIp: '203.0.113.7');
      expect(a.engine.deviceInfo.addrs.map((x) => x.ip), ['203.0.113.7']);
      final info = await getInfo(a.ip, a.port);
      expect(
        [for (final x in (info['addrs'] as List)) (x as Map)['ip']],
        ['203.0.113.7'],
      );
      expect(a.engine.myPeerLink!.ip, '203.0.113.7');
      expect(a.engine.myPeerLink!.toUri(), contains('ip=203.0.113.7'));
      final invite = Uri.parse(a.engine.createPairInvite());
      expect(invite.queryParameters['ip'], '203.0.113.7');
      expect(invite.queryParameters['port'], '${a.port}');
      // It is only what we tell others: the listener itself stays on the bind address.
      expect(a.engine.port, greaterThan(0));
      await presentedCertificate(a.ip, a.port);
    }, skip: skipAlias);

    test('without --advertise-ip the bind address is reported (twin), also in the plaintext profile', () async {
      final a = await rig.start('Alice');
      final legacy = await rig.start(
        'Legacy',
        secure: false,
        advertiseIp: '203.0.113.9',
      );
      expect(a.engine.deviceInfo.addrs.map((x) => x.ip), [a.ip]);
      expect(a.engine.myPeerLink!.ip, a.ip);
      expect(legacy.engine.deviceInfo.addrs.map((x) => x.ip), ['203.0.113.9']);
      final info = await getInfo(legacy.ip, legacy.port, tls: false);
      expect(
        [for (final x in (info['addrs'] as List)) (x as Map)['ip']],
        ['203.0.113.9'],
      );
    }, skip: skipAlias);

    test('an advertise address that is not an IP literal is refused', () async {
      final wiring = await SecurityWiring.open(
        directory: Directory(p.join(sandbox.path, 'id-adv')),
        deviceId: newDeviceId(),
      );
      addTearDown(wiring.close);
      expect(
        () => LibreShareEngine(
          self: DeviceInfo(
            deviceId: wiring.identity.identity.deviceId,
            alias: 'X',
            platform: 'linux',
          ),
          downloadDir: Directory(p.join(sandbox.path, 'rx')),
          security: wiring,
          advertiseIp: 'not an address',
        ),
        throwsArgumentError,
      );
    });
  });
}
