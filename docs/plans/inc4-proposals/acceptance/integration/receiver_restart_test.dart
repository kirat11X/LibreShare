// Inc 4 acceptance: FR-15 - a receiver that is killed (SIGKILL, no shutdown
// hook, no flush) at ~50 % and restarted on the same download directory lets
// the sender continue from the bitmap; the 24 h window; a changed manifest.
// docs/plans/inc4.md section 4, "integration/receiver_restart_test.dart".
//
// The receiver runs in a child process (test/helpers/inc4_receiver_main.dart)
// so that kill -9 is real. Every request that reaches it passes through an
// HttpRecordingProxy: that is the "server log" of the plan (PUT per chunk
// index and the status the receiver answered).
//
// Files are 80 MiB = 20 chunks of 4 MiB: the resume sidecar is persisted every
// 8 chunks (kResumePersistEvery), so a 50 % kill needs >= 16 chunks for a
// bitmap to exist at all.
//
// Scope note: plain profile only. The secure-profile restart (same identity
// directory, TLS, PIN guard state, docs/plans/inc4.md D3) needs a TLS-aware
// recorder and is NOT covered here.
@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/inc4_http_recorder.dart';
import '../helpers/inc4_rig.dart';
import '../helpers/test_data.dart';

const int size = 80 * mib;
const int chunks = 20;
final Set<int> all = {for (var i = 0; i < chunks; i++) i};

class Crash {
  late Directory sandbox;
  late Directory rxDir;
  late RecordLog log;
  late HttpRecordingProxy rec;
  late CrashableReceiver rx1;
  CrashableReceiver? rx2;
  late IncNode tx;
  late File src;
  Set<int> ackedAtKill = {};
  Set<int> persisted = {};
  bool sidecarFound = false;
  int boundary = 0;
  SendResult? first;
  SendResult? second;
  Object? secondError;

  /// Indices PUT (any outcome) after the restart.
  Set<int> get putAfterRestart => {
    for (final r in log.requests.skip(boundary))
      if (r.isChunkPut) r.chunkIndex!,
  };

  List<RecordedRequest> get putsAfterRestart => [
    for (final r in log.requests.skip(boundary))
      if (r.isChunkPut) r,
  ];

  File get finalFile => File(p.join(rxDir.path, p.basename(src.path)));

  Future<void> dispose() async {
    try {
      await rx1.kill9();
    } on Object {
      // already dead
    }
    try {
      await rx2?.kill9();
    } on Object {
      // ignore
    }
    await rec.close();
    await tx.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  }
}

Set<int> persistedFrom(File sidecar) {
  final j = jsonDecode(sidecar.readAsStringSync()) as Map<String, Object?>;
  final out = <int>{};
  for (final r in (j['received']! as List)) {
    final pair = (r as List).cast<int>();
    for (var i = pair[0]; i <= pair[1]; i++) {
      out.add(i);
    }
  }
  return out;
}

Future<Crash> runCrash({
  Duration restartClockOffset = Duration.zero,
  bool changeSourceBeforeResend = false,
}) async {
  final c = Crash();
  c.sandbox = Directory.systemTemp.createTempSync('ls_inc4_restart_');
  c.rxDir = Directory(p.join(c.sandbox.path, 'rx'))..createSync();
  c.log = RecordLog();
  c.rx1 = await CrashableReceiver.start(dir: c.rxDir);
  c.tx = await startNode(c.sandbox, 'tx');
  c.rec = await HttpRecordingProxy.start(targetPort: c.rx1.port, log: c.log);
  c.src = source(c.sandbox, 'resume.bin', size, seed: 15);

  final send1 = c.tx.engine.beginSendFiles(
    [c.src],
    host: '127.0.0.1',
    port: c.rec.port,
  );
  await untilTrue(
    () => c.log.ackedIndices.length >= chunks ~/ 2,
    timeout: const Duration(seconds: 90),
    what: '50 % of the chunks acknowledged',
  );
  await c.rx1.kill9(); // no dispose, no flush, no shutdown hook
  await Future<void>.delayed(const Duration(milliseconds: 400));
  c.ackedAtKill = c.log.ackedIndices;
  c.first = await send1.result.timeout(const Duration(seconds: 90));

  final sidecar = File('${c.finalFile.path}.lspart.json');
  c.sidecarFound = sidecar.existsSync();
  if (c.sidecarFound) c.persisted = persistedFrom(sidecar);

  if (changeSourceBeforeResend) {
    // Same name, different content and mtime: the manifest changes.
    c.src = source(c.sandbox, 'resume.bin', size, seed: 99);
    c.src.setLastModifiedSync(DateTime.now().add(const Duration(hours: 1)));
  }

  c.rx2 = await CrashableReceiver.start(
    dir: c.rxDir,
    clockOffset: restartClockOffset,
  );
  c.rec.targetPort = c.rx2!.port;
  c.boundary = c.log.requests.length;
  try {
    c.second = await c.tx.engine
        .beginSendFiles([c.src], host: '127.0.0.1', port: c.rec.port)
        .result
        .timeout(const Duration(seconds: 120));
  } on Object catch (e) {
    c.secondError = e;
  }
  return c;
}

void main() {
  group('FR-15: kill -9 at 50 %, restart on the same directory', () {
    late Crash c;
    setUpAll(() async {
      c = await runCrash();
      // ignore: avoid_print
      print(
        'restart scenario: first=${c.first} second=${c.second} '
        'ackedAtKill=${c.ackedAtKill.length} persisted=${c.persisted.length} '
        'putAfterRestart=${c.putAfterRestart.length}',
      );
    });
    tearDownAll(() => c.dispose());

    test('precondition: the first send failed (receiver dead) and the '
        'sidecar survived SIGKILL with the first persisted batch', () {
      expect(c.first?.status, TransferStatus.failed);
      expect(c.sidecarFound, isTrue, reason: 'no .lspart.json after SIGKILL');
      expect(
        c.persisted.length,
        greaterThanOrEqualTo(8),
        reason: 'persisted=${c.persisted}',
      );
      expect(c.persisted.difference(c.ackedAtKill), isEmpty);
    });

    test('FR-15 guard resume-completes-identical: second send COMPLETED, '
        'file byte-identical, no .lspart left', () async {
      expect(c.secondError, isNull, reason: '${c.secondError}');
      expect(c.second?.status, TransferStatus.completed, reason: '${c.second}');
      expect(c.finalFile.existsSync(), isTrue);
      expect(await sha256OfFileHex(c.finalFile), await sha256OfFileHex(c.src));
      expect(lsparts(c.rxDir), isEmpty);
    });

    test('FR-15 guard persisted-chunks-not-resent: no PUT after the restart '
        'for a chunk recorded in the sidecar', () {
      final again = c.putAfterRestart.intersection(c.persisted);
      expect(again, isEmpty, reason: 'persisted chunks sent again: $again');
    });

    test('FR-15 guard sends-only-the-missing: PUT set after the restart == '
        'all chunks minus the persisted ones', () {
      expect(c.putAfterRestart, all.difference(c.persisted));
    });

    test('FR-15 guard no-put-for-acked-chunk (spec wording, strict): no PUT '
        'after the restart for ANY chunk the receiver acknowledged before '
        'the kill', () {
      final again = c.putAfterRestart.intersection(c.ackedAtKill);
      expect(
        again,
        isEmpty,
        reason:
            'acked before the kill but sent again: $again '
            '(acked=${c.ackedAtKill.length}, persisted=${c.persisted.length})',
      );
    });
  });

  group('FR-15: 24 h window (receiver clock +25 h after the restart)', () {
    late Crash c;
    setUpAll(() async {
      c = await runCrash(restartClockOffset: const Duration(hours: 25));
      // ignore: avoid_print
      print(
        'stale scenario: second=${c.second} '
        'putAfterRestart=${c.putAfterRestart.length}',
      );
    });
    tearDownAll(() => c.dispose());

    test('guard sidecar-older-than-24h-discarded: nothing is resumed, every '
        'chunk is sent again, file identical', () async {
      expect(c.sidecarFound, isTrue, reason: 'precondition: sidecar existed');
      expect(c.persisted, isNotEmpty);
      expect(c.second?.status, TransferStatus.completed, reason: '${c.second}');
      expect(c.putAfterRestart, all, reason: 'a stale bitmap was honoured');
      expect(await sha256OfFileHex(c.finalFile), await sha256OfFileHex(c.src));
      expect(lsparts(c.rxDir), isEmpty);
    });
  });

  group('FR-15: manifest changed between the attempts', () {
    late Crash c;
    setUpAll(() async {
      c = await runCrash(changeSourceBeforeResend: true);
      // ignore: avoid_print
      print(
        'changed scenario: second=${c.second} '
        'putAfterRestart=${c.putAfterRestart.length}',
      );
    });
    tearDownAll(() => c.dispose());

    test('guard changed-manifest-restarts-from-0: all chunks sent, final file '
        'equals the NEW content (never a mix)', () async {
      expect(c.sidecarFound, isTrue, reason: 'precondition: sidecar existed');
      expect(c.second?.status, TransferStatus.completed, reason: '${c.second}');
      expect(c.putAfterRestart, all);
      expect(await sha256OfFileHex(c.finalFile), await sha256OfFileHex(c.src));
      expect(lsparts(c.rxDir), isEmpty);
    });
  });
}
