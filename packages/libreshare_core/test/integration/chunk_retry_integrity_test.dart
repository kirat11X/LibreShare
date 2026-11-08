// Inc 4 acceptance (section 4.1 negatives, end to end): a connection that is
// cut in the MIDDLE of an in-order chunk, followed by the sender's retry of
// that chunk in the same session, must still give a byte-identical, verified
// file. Real engines on loopback, a FaultyTcpProxy that cuts the first
// connection mid-body and then behaves.
//
// Why these shapes: the receiver keeps a running whole-file SHA-256 while
// in-order chunks arrive (file_receiver.dart putChunk, "inOrderForRunning").
// It is only used while chunks arrive strictly in order, i.e. for a file of
// ONE chunk (<= 4 MiB) or when the sender uploads one chunk at a time.
@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/faulty_tcp_proxy.dart';
import '../helpers/inc4_rig.dart';
import '../helpers/test_data.dart';

Future<void> scenario({
  required int size,
  required int concurrency,
  required int cutAfter,
  required String name,
}) async {
  final sandbox = Directory.systemTemp.createTempSync('ls_inc4_retry_');
  IncNode? rx;
  IncNode? tx;
  FaultyTcpProxy? proxy;
  Timer? watcher;
  try {
    rx = await startNode(sandbox, 'rx');
    tx = await startNode(sandbox, 'tx');
    proxy = await FaultyTcpProxy.start(
      targetAddress: '127.0.0.1',
      targetPort: rx.port,
    );
    final src = source(sandbox, name, size, seed: 77);
    proxy.cutAfter(
      cutAfter,
      direction: ProxyDirection.clientToServer,
      perConnection: true,
    );
    final px = proxy;
    watcher = Timer.periodic(const Duration(milliseconds: 2), (t) {
      if (px.faultsTriggered > 0) {
        px.resetFaults(); // the retry gets a clean path
        t.cancel();
      }
    });
    final res = await tx.engine
        .sendFiles(
          [src],
          host: '127.0.0.1',
          port: proxy.port,
          chunkConcurrency: concurrency,
        )
        .timeout(const Duration(seconds: 90));
    expect(proxy.faultsTriggered, greaterThan(0), reason: 'no fault happened');
    expect(
      res.status,
      TransferStatus.completed,
      reason:
          'a cut mid-chunk then a retry in the same session must still '
          'verify: $res',
    );
    final out = File(p.join(rx.rx.path, name));
    expect(await sha256OfFileHex(out), await sha256OfFileHex(src));
    expect(lsparts(rx.rx), isEmpty);
  } finally {
    watcher?.cancel();
    await proxy?.close();
    await tx?.dispose();
    await rx?.dispose();
    sandbox.deleteSync(recursive: true);
  }
}

void main() {
  test('guard retry-after-midchunk-cut-single-chunk: a 3 MiB file (one chunk) '
      'cut at 1 MiB, retried, verifies', () {
    return scenario(
      size: 3 * mib,
      concurrency: 3,
      cutAfter: 1 * mib,
      name: 'one.bin',
    );
  });

  test('guard retry-after-midchunk-cut-sequential: a 12 MiB file sent one '
      'chunk at a time, cut inside the second chunk, retried, verifies', () {
    return scenario(
      size: 12 * mib,
      concurrency: 1,
      cutAfter: 6 * mib,
      name: 'seq.bin',
    );
  });
}
