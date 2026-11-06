// C5 independent re-verification (second tester, 2026-11-06).
// Closes two survivors the Lead's review missed:
//  1. the engine's TLS-alert branch: InsecurePeerException must not fall back
//     to plaintext;
//  2. the default of SecurityWiring.open(allowInsecurePeers), which the
//     Flutter app relies on.
// The second test needs `openssl` and skips without it.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/p6a_support.dart';

bool _hasOpenssl() {
  try {
    return Process.runSync('openssl', ['version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<void> main() async {
  final skip = await p6aSkipReason();
  late Directory sandbox;
  late P6aRig rig;
  Process? proc;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('ls_c5rv_');
    rig = P6aRig(sandbox);
  });

  tearDown(() async {
    proc?.kill();
    if (proc != null) await proc!.exitCode;
    proc = null;
    for (final n in rig.nodes) {
      await n.dispose();
    }
    if (sandbox.existsSync()) await sandbox.delete(recursive: true);
  });

  test('SecurityWiring.open defaults to allowInsecurePeers == false', () async {
    final w = await SecurityWiring.open(
      directory: Directory(p.join(sandbox.path, 'id')),
      deviceId: newDeviceId(),
    );
    addTearDown(w.close);
    expect(w.config.allowInsecurePeers, isFalse);
  });

  test('engine refuses (InsecurePeerException) a peer whose TLS handshake fails with a TLS alert '
      '(TLS 1.2-only server), allowInsecurePeers=false, and opens no plaintext connection', () async {
    final a = await rig.start('Alice', secure: true);
    final other = await rig.start('Other', secure: true, ip: '127.0.0.9');
    final id = other.wiring!.identity;
    final tmp = Directory(p.join(sandbox.path, 'ossl'))..createSync();
    File(p.join(tmp.path, 'cert.pem')).writeAsStringSync(id.identity.certPem);
    File(p.join(tmp.path, 'key.pem')).writeAsBytesSync(id.privateKeyPem());
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    final ready = Completer<void>();
    proc = await Process.start('openssl', [
      's_server',
      '-accept',
      '$port',
      '-cert',
      p.join(tmp.path, 'cert.pem'),
      '-key',
      p.join(tmp.path, 'key.pem'),
      '-www',
      '-tls1_2',
    ]);
    proc!.stdout.transform(utf8.decoder).listen((c) {
      if (c.contains('ACCEPT') && !ready.isCompleted) ready.complete();
    });
    unawaited(proc!.stderr.drain<void>());
    await ready.future.timeout(const Duration(seconds: 10));
    final f = File(p.join(sandbox.path, 'x.bin'))
      ..writeAsBytesSync(List.filled(64, 7));
    await expectLater(
      a.engine.sendFiles([f], host: '127.0.0.1', port: port),
      throwsA(isA<InsecurePeerException>()),
    );
  }, skip: skip ?? (_hasOpenssl() ? null : 'openssl is not installed'));
}
