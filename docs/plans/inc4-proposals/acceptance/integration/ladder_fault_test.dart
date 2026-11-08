// Inc 4 acceptance: FR-12 (tier 1 first when healthy, deterministic order)
// and FR-13 (fall back to tier 2 within 10 s of a tier-1 cut, no ACKED chunk
// re-sent). docs/plans/inc4.md section 4, "integration/ladder_fault_test.dart".
//
// Topology (plain HTTP on loopback, real engines, real ConnectionManager):
//   sender engine --candidate wifi--> FaultyTcpProxy --> HttpRecordingProxy R1 --\
//                 \--candidate lan---> HttpRecordingProxy R2 -------------------->  receiver engine
// R1/R2 record every request that reaches the receiver (method, path, body
// bytes forwarded, status answered): that is "the receiver log" of the plan.
// The scenario files are 40 MiB = 10 chunks of 4 MiB, so a cut at 40 % of the
// bytes lands inside chunk 3 or 4 with chunks 0..2 already acknowledged.
//
// Entry point under test: LibreShareEngine.beginSendToCandidates(...,
// candidates: [...], enableFallback: true).
@TestOn('vm')
@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/faulty_tcp_proxy.dart';
import '../helpers/inc4_http_recorder.dart';
import '../helpers/inc4_rig.dart';
import '../helpers/test_data.dart';

class Env {
  late Directory sandbox;
  late IncNode rx;
  late IncNode tx;
  late RecordLog log;
  late HttpRecordingProxy r1; // behind the faulty tier-1 proxy
  late HttpRecordingProxy r2; // direct tier 2
  late FaultyTcpProxy p1;
  late Candidate tier1;
  late Candidate tier2;

  static Future<Env> start() async {
    final e = Env();
    e.sandbox = Directory.systemTemp.createTempSync('ls_inc4_ladder_');
    e.rx = await startNode(e.sandbox, 'rx');
    e.tx = await startNode(e.sandbox, 'tx');
    e.log = RecordLog();
    e.r1 = await HttpRecordingProxy.start(
      targetPort: e.rx.port,
      log: e.log,
      label: 'tier1',
    );
    e.r2 = await HttpRecordingProxy.start(
      targetPort: e.rx.port,
      log: e.log,
      label: 'tier2',
    );
    e.p1 = await FaultyTcpProxy.start(
      targetAddress: '127.0.0.1',
      targetPort: e.r1.port,
    );
    e.tier1 = candidate(CandidateKind.wifi, e.p1.port);
    e.tier2 = candidate(CandidateKind.lan, e.r2.port);
    return e;
  }

  Future<void> dispose() async {
    await p1.close();
    await r1.close();
    await r2.close();
    await tx.dispose();
    await rx.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  }
}

class Run {
  SendResult? result;
  Object? error;
  DateTime? faultAt;
  late File file;
  late int size;
}

/// Sends [file] with the given candidate order; remembers when the proxy first
/// triggered a fault.
Future<Run> runSend(
  Env e,
  File file,
  List<Candidate> order, {
  Duration cap = const Duration(seconds: 90),
}) async {
  final run = Run()
    ..file = file
    ..size = file.lengthSync();
  final watcher = Timer.periodic(const Duration(milliseconds: 5), (_) {
    if (run.faultAt == null && e.p1.faultsTriggered > 0) {
      run.faultAt = DateTime.now();
    }
  });
  try {
    final send = e.tx.engine.beginSendToCandidates(
      deviceFor(e.rx),
      [file],
      candidates: order,
      enableFallback: true,
    );
    run.result = await send.result.timeout(cap);
  } on Object catch (err) {
    run.error = err;
  } finally {
    watcher.cancel();
  }
  return run;
}

Set<int> range(int n) => {for (var i = 0; i < n; i++) i};

void main() {
  const size = 40 * mib;
  const chunks = 10;

  // ------------------------------------------------------------ FR-13 cut
  group('FR-13: tier 1 cut at ~40 % of the bytes', () {
    late Env env;
    late Run run;
    late File src;

    setUpAll(() async {
      env = await Env.start();
      src = source(env.sandbox, 'cut.bin', size, seed: 13);
      env.p1.cutAfter(
        (size * 0.4).round(),
        direction: ProxyDirection.clientToServer,
      );
      run = await runSend(env, src, [env.tier1, env.tier2]);
      // ignore: avoid_print
      print(
        'cut scenario: result=${run.result} error=${run.error} '
        'faults=${env.p1.faultsTriggered} '
        'switches=${env.tx.channelEvents.whereType<ChannelTierSwitched>().length}',
      );
    });
    tearDownAll(() => env.dispose());

    test('precondition: the proxy really cut the tier-1 path mid-transfer', () {
      expect(env.p1.faultsTriggered, greaterThan(0));
      final fwd = env.p1.stats.clientToServerBytes;
      expect(fwd, greaterThan(size * 0.3), reason: 'cut too early: $fwd B');
      expect(fwd, lessThan(size * 0.7), reason: 'cut too late: $fwd B');
      expect(
        env.log.requests.where((r) => r.label == 'tier1' && r.isChunkPut),
        isNotEmpty,
        reason: 'tier 1 must have carried chunks before the cut',
      );
    });

    test(
      'FR-13 guard completes-on-tier-2: COMPLETED and byte-identical',
      () async {
        expect(run.error, isNull, reason: 'send threw: ${run.error}');
        expect(
          run.result?.status,
          TransferStatus.completed,
          reason:
              'the send must finish on tier 2 after the tier-1 cut; got '
              '${run.result}',
        );
        final out = File(p.join(env.rx.rx.path, p.basename(src.path)));
        expect(
          out.existsSync(),
          isTrue,
          reason: 'file missing at the receiver',
        );
        expect(out.lengthSync(), size);
        expect(await sha256OfFileHex(out), await sha256OfFileHex(src));
        expect(lsparts(env.rx.rx), isEmpty);
      },
    );

    test(
      'FR-13 guard tier-switched-event: ChannelTierSwitched wifi -> lan',
      () {
        final switches = env.tx.channelEvents
            .whereType<ChannelTierSwitched>()
            .toList();
        expect(switches, isNotEmpty, reason: 'no ChannelTierSwitched emitted');
        expect(switches.first.fromCandidate?.kind, CandidateKind.wifi);
        expect(switches.first.toCandidate.kind, CandidateKind.lan);
      },
    );

    test('FR-13 guard switch-within-10s: switch <= 10 s after the cut', () {
      final cut = run.faultAt;
      final sw = env.tx.firstSwitchAt;
      expect(cut, isNotNull, reason: 'the fault was not observed');
      expect(sw, isNotNull, reason: 'no tier switch observed');
      final took = sw!.difference(cut!);
      expect(
        took,
        lessThanOrEqualTo(const Duration(seconds: 10)),
        reason: 'switch took $took',
      );
    });

    test('FR-13 guard no-acked-chunk-resent: every chunk acked exactly once, '
        'never PUT again after its ack (receiver-side log)', () {
      final bad = env.log.resentAfterAck();
      expect(bad, isEmpty, reason: bad.join('\n'));
      expect(
        env.log.ackedIndices,
        range(chunks),
        reason: 'all $chunks chunks must be acked: ${env.log.chunkPuts}',
      );
      for (final entry in env.log.putCounts.entries) {
        final acks = env.log.chunkPuts
            .where((r) => r.chunkIndex == entry.key && r.acked)
            .length;
        expect(acks, 1, reason: 'chunk ${entry.key} acked $acks times');
      }
    });

    test('FR-13 guard tier-2-carries-the-rest: chunks acked on tier 1 are '
        'not PUT on tier 2', () {
      final onTier1 = {
        for (final r in env.log.chunkPuts)
          if (r.label == 'tier1' && r.acked) r.chunkIndex!,
      };
      final onTier2 = {
        for (final r in env.log.chunkPuts)
          if (r.label == 'tier2') r.chunkIndex!,
      };
      expect(onTier2, isNotEmpty, reason: 'tier 2 carried nothing');
      expect(onTier1.intersection(onTier2), isEmpty);
    });
  });

  // ------------------------------------------------- FR-12 healthy ladder
  group('FR-12: both tiers healthy', () {
    late Env env;
    final runs = <Run>[];
    final startIdx = <int>[];

    setUpAll(() async {
      env = await Env.start();
      // The same ladder, given in both candidate orders, twice each.
      var n = 0;
      for (final order in [
        [env.tier1, env.tier2],
        [env.tier2, env.tier1],
        [env.tier1, env.tier2],
        [env.tier2, env.tier1],
      ]) {
        final f = source(env.sandbox, 'ok$n.bin', 12 * mib, seed: 20 + n++);
        startIdx.add(env.tx.events.length);
        runs.add(await runSend(env, f, order));
      }
    });
    tearDownAll(() => env.dispose());

    test(
      'FR-12 guard completes-and-identical: all four sends COMPLETED',
      () async {
        for (var i = 0; i < runs.length; i++) {
          expect(runs[i].error, isNull);
          expect(
            runs[i].result?.status,
            TransferStatus.completed,
            reason: '#$i',
          );
          final out = File(
            p.join(env.rx.rx.path, p.basename(runs[i].file.path)),
          );
          expect(
            await sha256OfFileHex(out),
            await sha256OfFileHex(runs[i].file),
          );
        }
      },
    );

    test('FR-12 guard tier-1-first: the first connection of every send is '
        'tier 1, whatever the candidate order given', () {
      for (var i = 0; i < runs.length; i++) {
        final evs = env.tx.events
            .skip(startIdx[i])
            .take(
              i + 1 < startIdx.length ? startIdx[i + 1] - startIdx[i] : 1 << 30,
            )
            .whereType<ChannelStateChanged>()
            .map((e) => e.event)
            .toList();
        final active = evs.whereType<ChannelActive>().toList();
        expect(active, isNotEmpty, reason: 'send #$i: no ChannelActive');
        expect(
          active.first.candidate.kind,
          CandidateKind.wifi,
          reason: 'send #$i connected first to ${active.first.candidate}',
        );
        expect(evs.whereType<ChannelTierSwitched>(), isEmpty, reason: '#$i');
        expect(evs.whereType<ChannelFailed>(), isEmpty, reason: '#$i');
      }
    });

    test('FR-12 guard every-chunk-on-tier-1: tier 2 sees no request at all, '
        'tier 1 carries every chunk of every send', () {
      expect(
        env.log.requests.where((r) => r.label == 'tier2'),
        isEmpty,
        reason: 'tier 2 was used although tier 1 was healthy',
      );
      final puts = env.log.chunkPuts.where((r) => r.label == 'tier1').toList();
      expect(puts.where((r) => r.acked), hasLength(runs.length * 3));
    });
  });

  // ----------------------------------------------------- hysteresis / flap
  group('tier 1 flaps (down 2 s / up 2 s)', () {
    late Env env;
    late Run run;
    late File src;
    var flaps = 0;

    setUpAll(() async {
      env = await Env.start();
      src = source(env.sandbox, 'flap.bin', size, seed: 31);
      // Tier 1 carries 4 MiB/s at most, whatever the CPU or hash speed: the
      // 40 MiB send needs >= 10 s on tier 1, so the first down-window (2 s)
      // always falls inside the transfer.
      env.r1.bytesPerSecond = 4 * mib;
      env.p1.delay(const Duration(milliseconds: 15));
      // up at t=0; down 1-3 s, up 3-5 s, down 5-7 s ... until the end.
      var down = false;
      final t = Timer.periodic(const Duration(seconds: 2), (_) {
        flaps++;
        if (!down) {
          env.p1.resetConnection(futureConnections: true);
        } else {
          env.p1.resetFaults();
          env.p1.delay(const Duration(milliseconds: 15));
        }
        down = !down;
      });
      run = await runSend(env, src, [env.tier1, env.tier2]);
      t.cancel();
      // ignore: avoid_print
      print('flap scenario: result=${run.result} flaps=$flaps');
    });
    tearDownAll(() => env.dispose());

    test('guard flap-completes: COMPLETED, byte-identical', () async {
      expect(run.error, isNull, reason: '${run.error}');
      expect(
        run.result?.status,
        TransferStatus.completed,
        reason: 'got ${run.result} after $flaps flap toggles',
      );
      final out = File(p.join(env.rx.rx.path, p.basename(src.path)));
      expect(await sha256OfFileHex(out), await sha256OfFileHex(src));
    });

    test('guard flap-no-thrash: at most one tier switch, never back to '
        'tier 1, no acked chunk re-sent', () {
      final switches = env.tx.channelEvents
          .whereType<ChannelTierSwitched>()
          .toList();
      expect(flaps, greaterThanOrEqualTo(1), reason: 'the path never flapped');
      expect(switches.length, lessThanOrEqualTo(1), reason: '$switches');
      expect(
        switches.where((s) => s.toCandidate.kind == CandidateKind.wifi),
        isEmpty,
        reason: 'switched back to tier 1: $switches',
      );
    });

    // Split out of the test above after its first run (assertion kept as it
    // was, only given its own name so the two verdicts are not mixed): a
    // reset destroys the response as well as the request, so the sender does
    // not know the receiver already acknowledged the chunk.
    test(
      'guard flap-no-acked-chunk-resent: no chunk is PUT again after the '
      'receiver acknowledged it, even when the ack was lost in the reset',
      () {
        expect(env.log.resentAfterAck(), isEmpty);
      },
    );
  });
}
