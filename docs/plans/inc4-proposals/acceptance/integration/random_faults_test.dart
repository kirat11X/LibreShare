// Inc 4 acceptance: NFR-03 - 20 randomised fault runs. Each seed drives a
// FaultyTcpProxy between a sender and a receiver engine with a seeded mix of
// per-connection cuts, truncations, delays, bit flips and a one-shot reset.
// Each of the 20 seeds must end
//   * COMPLETED with a byte-identical file and no .lspart left, or
//   * FAILED with a consistent, resumable state: no final file with wrong
//     bytes, every .lspart paired with its sidecar (and vice versa), and a
//     fresh receiver on the same directory finishes the transfer through a
//     clean path with a byte-identical result.
// The seed and its schedule are printed first, so a failure replays with
//   dart test --tags slow test/integration/random_faults_test.dart -N "seed 7"
// docs/plans/inc4.md section 4 (NFR-03), "integration/random_faults_test.dart".
@Tags(['slow'])
@TestOn('vm')
@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/faulty_tcp_proxy.dart';
import '../helpers/inc4_rig.dart';
import '../helpers/test_data.dart';

const int size = 12 * mib; // 3 chunks of 4 MiB

/// Applies the seeded schedule to [proxy]; returns a one-line description.
String applySchedule(int seed, FaultyTcpProxy proxy, List<Timer> timers) {
  final rng = Random(seed);
  final parts = <String>[];
  bool pick() => rng.nextBool();
  var any = false;
  if (pick()) {
    final ms = 5 + rng.nextInt(36);
    proxy.delay(Duration(milliseconds: ms));
    parts.add('delay ${ms}ms');
    any = true;
  }
  if (pick()) {
    final n = 2 * mib + rng.nextInt(12 * mib);
    proxy.cutAfter(
      n,
      direction: ProxyDirection.clientToServer,
      perConnection: true,
    );
    parts.add('cut/conn after $n B');
    any = true;
  }
  if (pick()) {
    final n = 2 * mib + rng.nextInt(12 * mib);
    final abrupt = rng.nextBool();
    proxy.truncate(
      n,
      direction: ProxyDirection.clientToServer,
      abrupt: abrupt,
      perConnection: true,
    );
    parts.add('truncate/conn after $n B abrupt=$abrupt');
    any = true;
  }
  if (pick()) {
    final prob = 5e-8 + rng.nextDouble() * 2.5e-7;
    proxy.bitFlip(prob, seed: seed, direction: ProxyDirection.clientToServer);
    parts.add('bitflip p=${prob.toStringAsExponential(2)}');
    any = true;
  }
  if (pick() || !any) {
    final at = 200 + rng.nextInt(1800);
    timers.add(Timer(Duration(milliseconds: at), proxy.resetConnection));
    parts.add('reset at ${at}ms');
  }
  return parts.join(', ');
}

void main() {
  for (var seed = 1; seed <= 20; seed++) {
    test(
      'NFR-03 seed $seed: COMPLETED identical or FAILED resumable',
      () async {
        final sandbox = Directory.systemTemp.createTempSync('ls_inc4_rand_');
        final timers = <Timer>[];
        IncNode? rx;
        IncNode? tx;
        IncNode? rx2;
        FaultyTcpProxy? proxy;
        try {
          rx = await startNode(sandbox, 'rx');
          tx = await startNode(sandbox, 'tx');
          proxy = await FaultyTcpProxy.start(
            targetAddress: '127.0.0.1',
            targetPort: rx.port,
          );
          final src = source(sandbox, 'f$seed.bin', size, seed: 100 + seed);
          final desc = applySchedule(seed, proxy, timers);
          // ignore: avoid_print
          print('NFR-03 seed=$seed schedule: $desc');

          SendResult? res;
          Object? err;
          try {
            res = await tx.engine
                .beginSendFiles([src], host: '127.0.0.1', port: proxy.port)
                .result
                .timeout(const Duration(seconds: 90));
          } on Object catch (e) {
            err = e;
          }
          for (final t in timers) {
            t.cancel();
          }
          final tag = 'seed=$seed [$desc] result=$res error=$err';
          // ignore: avoid_print
          print('NFR-03 seed=$seed outcome: $res ${err ?? ''}');

          final out = File(p.join(rx.rx.path, p.basename(src.path)));
          if (res != null && res.status == TransferStatus.completed) {
            expect(out.existsSync(), isTrue, reason: tag);
            expect(
              await sha256OfFileHex(out),
              await sha256OfFileHex(src),
              reason: 'COMPLETED but not identical: $tag',
            );
            expect(lsparts(rx.rx), isEmpty, reason: 'leftovers: $tag');
            return;
          }

          // FAILED (or the call itself threw / hung): the state must be safe.
          expect(
            err,
            isNull,
            reason: 'send() threw/hung instead of FAILED: $tag',
          );
          expect(res!.status, TransferStatus.failed, reason: tag);
          if (out.existsSync()) {
            expect(
              await sha256OfFileHex(out),
              await sha256OfFileHex(src),
              reason: 'FAILED yet a wrong final file exists: $tag',
            );
          }
          final left = lsparts(rx.rx);
          final parts = {
            for (final f in left)
              if (!f.endsWith('.json')) f,
          };
          final sidecars = {
            for (final f in left)
              if (f.endsWith('.json')) f.substring(0, f.length - 5),
          };
          expect(
            parts,
            sidecars,
            reason: 'partial/sidecar not paired: $left; $tag',
          );

          // Resumable: a fresh receiver on the same dir, clean path, finishes.
          final dir = rx.rx;
          await proxy.close();
          proxy = null;
          await rx.dispose();
          rx = null;
          rx2 = await startNode(sandbox, 'rx2', rx: dir);
          final res2 = await tx.engine
              .beginSendFiles([src], host: '127.0.0.1', port: rx2.port)
              .result
              .timeout(const Duration(seconds: 90));
          expect(
            res2.status,
            TransferStatus.completed,
            reason: 'not resumable after FAILED: $res2; $tag',
          );
          final names = Directory(dir.path)
              .listSync()
              .whereType<File>()
              .map((f) => p.basename(f.path))
              .where((n) => !n.contains('.lspart'))
              .toList();
          expect(names, [
            p.basename(src.path),
          ], reason: 'resume produced extra files $names; $tag');
          expect(
            await sha256OfFileHex(File(p.join(dir.path, names.single))),
            await sha256OfFileHex(src),
            reason: tag,
          );
          expect(lsparts(dir), isEmpty, reason: tag);
        } finally {
          for (final t in timers) {
            t.cancel();
          }
          await proxy?.close();
          await tx?.dispose();
          await rx?.dispose();
          await rx2?.dispose();
          if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
        }
      },
    );
  }
}
