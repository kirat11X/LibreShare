// Speed wave S2 (tester): receiver-verification scenarios shared by
//  * test/integration/receiver_verification_characterization_test.dart
//    (uses NO S2 symbol: green today, must stay green), and
//  * test/integration/native_sha256_transfer_test.dart (same scenarios while
//    a native / pure-Dart provider is installed).
// Only existing public API is used here.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_data.dart';

const int kChunkBytes = 4 * 1024 * 1024;

/// 6 chunks, the last one short (partial SHA-256 block at the very end).
const int kShortLastSize = 6 * kChunkBytes - 37;

const _self = DeviceInfo(
  deviceId: 'rx-id',
  alias: 'Receiver',
  platform: 'linux',
);
const _senderDev = DeviceInfo(
  deviceId: 'tx-id',
  alias: 'Sender',
  platform: 'linux',
);

Matcher throwsLsCode(LsErrorCode code) =>
    throwsA(isA<LsException>().having((e) => e.code, 'code', code));

Uint8List seededBytes(int n, int seed) {
  final r = Random(seed);
  final b = Uint8List(n);
  final w = b.buffer.asUint32List(0, n ~/ 4);
  for (var i = 0; i < w.length; i++) {
    w[i] = r.nextInt(0x100000000);
  }
  for (var i = w.length * 4; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

String shaHexOf(List<int> b) => sha256.convert(b).toString();

/// Lazily built, process-wide test content (so each scenario does not pay for
/// generating and hashing 24 MiB again).
class Content {
  Content.of(this.data)
    : chunkCount = (data.length + kChunkBytes - 1) ~/ kChunkBytes {
    chunkHashes = [for (var i = 0; i < chunkCount; i++) shaHexOf(chunk(i))];
    wholeHash = shaHexOf(data);
  }
  static final Content big = Content.of(seededBytes(kShortLastSize, 4242));
  final Uint8List data;
  final int chunkCount;
  late final List<String> chunkHashes;
  late final String wholeHash;

  Uint8List chunk(int i) => Uint8List.sublistView(
    data,
    i * kChunkBytes,
    min((i + 1) * kChunkBytes, data.length),
  );
}

class RxRig {
  late Directory tmp;
  late Directory dl;
  final receivers = <FileReceiver>[];

  void setUp() {
    tmp = Directory.systemTemp.createTempSync('ls_s2_rx_');
    dl = Directory(p.join(tmp.path, 'Downloads'))..createSync();
  }

  void tearDown() {
    for (final r in receivers) {
      r.dispose();
    }
    receivers.clear();
    tmp.deleteSync(recursive: true);
  }

  FileReceiver newReceiver() {
    final r = FileReceiver(
      self: _self,
      downloadDir: dl,
      autoAccept: true,
      clock: const SystemClock(),
      onEvent: (_) {},
      freeSpaceProbe: (_) async => null,
    );
    receivers.add(r);
    return r;
  }

  /// Opens a session for the big content. [manifestSha] overrides the
  /// manifest hash ('' = omit it, null = the right one).
  Future<(String, String)> open(
    FileReceiver rx, {
    String? manifestSha,
    String name = 'big.bin',
    Content? content,
  }) async {
    final c = content ?? Content.big;
    final item = FileItem(
      fileId: 'f',
      fileName: name,
      size: c.data.length,
      chunkCount: c.chunkCount,
      sha256: manifestSha == null
          ? c.wholeHash
          : (manifestSha.isEmpty ? null : manifestSha),
    );
    final st = await rx.createSession(
      SessionRequest(
        sender: _senderDev,
        files: [item],
        totalSize: c.data.length,
        chunkSize: kChunkBytes,
      ),
      remoteAddress: '127.0.0.1',
    );
    expect(st.status, TransferStatus.inProgress);
    return (st.sessionId, st.acceptedFiles['f']!.token);
  }

  /// Sends chunk [index]; [body] overrides the bytes (header hash stays the
  /// hash of the genuine chunk, like a corrupted transfer).
  Future<void> sendChunk(
    FileReceiver rx,
    String sid,
    String tok,
    int index, {
    bool withHash = true,
    Uint8List? body,
    int pieceSize = 1000003,
    Content? content,
  }) {
    final c = content ?? Content.big;
    final bytes = body ?? c.chunk(index);
    Stream<List<int>> stream() async* {
      for (var i = 0; i < bytes.length; i += pieceSize) {
        // views with offsetInBytes != 0 and odd lengths on purpose
        yield Uint8List.sublistView(bytes, i, min(i + pieceSize, bytes.length));
      }
    }

    return rx.putChunk(
      sid,
      'f',
      index,
      stream(),
      token: tok,
      chunkSha256: withHash ? c.chunkHashes[index] : null,
    );
  }

  Future<Set<int>> stored(FileReceiver rx, String sid, String tok) async {
    final ranges = (await rx.fileState(sid, 'f', token: tok)).receivedRanges;
    return {
      for (final r in ranges)
        for (var i = r[0]; i <= r[1]; i++) i,
    };
  }

  File finalFile(String name) => File(p.join(dl.path, name));

  List<String> leftovers() => partialLeftovers(dl);
}

const _orders = <String, List<int>>{
  'in order': [0, 1, 2, 3, 4, 5],
  'first chunk last': [3, 0, 1, 2, 5, 4],
  'gap in the middle': [0, 1, 3, 2, 4, 5],
};

/// Defines the receiver-verification tests (behaviour 6) in the current group.
void defineReceiverVerificationTests() {
  final rig = RxRig();
  setUp(rig.setUp);
  tearDown(rig.tearDown);

  for (final o in _orders.entries) {
    test('${o.key}: COMPLETED with byte-identical output', () async {
      final rx = rig.newReceiver();
      final (sid, tok) = await rig.open(rx);
      for (final i in o.value) {
        await rig.sendChunk(rx, sid, tok, i);
      }
      final v = await rx.completeFile(sid, 'f', token: tok);
      expect(v.verified, isTrue);
      expect(v.sha256, Content.big.wholeHash);
      final st = await rx.finish(sid);
      expect(st.status, TransferStatus.completed);
      expect(rig.finalFile('big.bin').readAsBytesSync(), Content.big.data);
      expect(rig.leftovers(), isEmpty);
    });
  }

  test('flipped bit in the middle of chunk 2: chunk-hash error, chunk not '
      'stored, a genuine resend completes the file', () async {
    final rx = rig.newReceiver();
    final (sid, tok) = await rig.open(rx);
    await rig.sendChunk(rx, sid, tok, 0);
    await rig.sendChunk(rx, sid, tok, 1);
    final bad = Uint8List.fromList(Content.big.chunk(2))..[1000003] ^= 0x10;
    await expectLater(
      rig.sendChunk(rx, sid, tok, 2, body: bad),
      throwsLsCode(LsErrorCode.chunkHashMismatch),
    );
    expect(await rig.stored(rx, sid, tok), {0, 1});
    await rig.sendChunk(rx, sid, tok, 2);
    for (final i in [3, 4, 5]) {
      await rig.sendChunk(rx, sid, tok, i);
    }
    final v = await rx.completeFile(sid, 'f', token: tok);
    expect(v.verified, isTrue);
    expect(rig.finalFile('big.bin').readAsBytesSync(), Content.big.data);
  });

  test('flipped bit in the very last byte of the short last chunk is '
      'rejected', () async {
    final rx = rig.newReceiver();
    final (sid, tok) = await rig.open(rx);
    final bad = Uint8List.fromList(Content.big.chunk(5));
    bad[bad.length - 1] ^= 0x01;
    await expectLater(
      rig.sendChunk(rx, sid, tok, 5, body: bad),
      throwsLsCode(LsErrorCode.chunkHashMismatch),
    );
    expect(await rig.stored(rx, sid, tok), isEmpty);
  });

  test('flipped bit in the first byte of chunk 0 is rejected', () async {
    final rx = rig.newReceiver();
    final (sid, tok) = await rig.open(rx);
    final bad = Uint8List.fromList(Content.big.chunk(0))..[0] ^= 0x80;
    await expectLater(
      rig.sendChunk(rx, sid, tok, 0, body: bad),
      throwsLsCode(LsErrorCode.chunkHashMismatch),
    );
    expect(await rig.stored(rx, sid, tok), isEmpty);
  });

  for (final o in _orders.entries) {
    test('${o.key}, no per-chunk header, one flipped bit: whole-file check '
        '-> FAILED/verifyFailed, no partial left', () async {
      final rx = rig.newReceiver();
      final (sid, tok) = await rig.open(rx);
      for (final i in o.value) {
        final body = i == 4
            ? (Uint8List.fromList(Content.big.chunk(4))..[777] ^= 0x04)
            : null;
        await rig.sendChunk(rx, sid, tok, i, withHash: false, body: body);
      }
      await expectLater(
        rx.completeFile(sid, 'f', token: tok),
        throwsLsCode(LsErrorCode.verifyFailed),
      );
      final st = await rx.getSession(sid);
      expect(st.status, TransferStatus.failed);
      expect(st.failureReason, FailureReason.verifyFailed);
      expect(rig.finalFile('big.bin').existsSync(), isFalse);
      expect(rig.leftovers(), isEmpty);
    });

    test('${o.key}, intact chunks but wrong manifest hash: '
        'FAILED/verifyFailed, no partial left', () async {
      final rx = rig.newReceiver();
      final (sid, tok) = await rig.open(
        rx,
        manifestSha: shaHexOf(seededBytes(100, 5)),
      );
      for (final i in o.value) {
        await rig.sendChunk(rx, sid, tok, i);
      }
      await expectLater(
        rx.completeFile(sid, 'f', token: tok),
        throwsLsCode(LsErrorCode.verifyFailed),
      );
      final st = await rx.getSession(sid);
      expect(st.status, TransferStatus.failed);
      expect(st.failureReason, FailureReason.verifyFailed);
      expect(rig.finalFile('big.bin').existsSync(), isFalse);
      expect(rig.leftovers(), isEmpty);
    });
  }

  test('manifest hash omitted: wrong hash at /complete fails, the right one '
      'completes (in order)', () async {
    final rx = rig.newReceiver();
    final (sid, tok) = await rig.open(rx, manifestSha: '');
    for (var i = 0; i < Content.big.chunkCount; i++) {
      await rig.sendChunk(rx, sid, tok, i);
    }
    await expectLater(
      rx.completeFile(sid, 'f', token: tok, sha256: 'a' * 64),
      throwsLsCode(LsErrorCode.verifyFailed),
    );
    expect(rig.finalFile('big.bin').existsSync(), isFalse);

    final rx2 = rig.newReceiver();
    final (sid2, tok2) = await rig.open(rx2, manifestSha: '', name: 'b2.bin');
    for (var i = 0; i < Content.big.chunkCount; i++) {
      await rig.sendChunk(rx2, sid2, tok2, i);
    }
    final v = await rx2.completeFile(
      sid2,
      'f',
      token: tok2,
      sha256: Content.big.wholeHash,
    );
    expect(v.verified, isTrue);
    expect(rig.finalFile('b2.bin').readAsBytesSync(), Content.big.data);
  });
}

LibreShareEngine newLoopbackEngine(String name, Directory dl) =>
    LibreShareEngine(
      self: DeviceInfo(
        deviceId: 'device-$name',
        alias: 'Engine-$name',
        platform: 'linux',
      ),
      downloadDir: dl,
      preferredPort: 0,
      bindAddress: InternetAddress.loopbackIPv4,
      enableRateLimit: false,
    );

/// Sends a 24 MiB (6 x 4 MiB) file engine -> engine over loopback.
/// [beforeSend] runs after both engines are constructed and started (so a test
/// can install a provider that the engine constructor would otherwise
/// replace).
Future<void> engineRoundTrip24MiB({
  FutureOr<void> Function()? beforeSend,
}) async {
  final sandbox = Directory.systemTemp.createTempSync('ls_s2_eng_');
  final tx = newLoopbackEngine('tx', Directory(p.join(sandbox.path, 'tx-dl')));
  final rxDir = Directory(p.join(sandbox.path, 'rx'));
  final rx = newLoopbackEngine('rx', rxDir);
  try {
    await tx.start();
    await rx.start();
    const size = 6 * kChunkBytes;
    final src = writeRandomFile(
      Directory(p.join(sandbox.path, 'src')),
      'm24.bin',
      size,
      seed: 24,
    );
    await beforeSend?.call();
    final res = await tx.sendFiles([src], host: '127.0.0.1', port: rx.port);
    expect(res.status, TransferStatus.completed, reason: '$res');
    expect(res.bytesSent, size);
    final dst = File(p.join(rxDir.path, 'm24.bin'));
    expect(dst.lengthSync(), size);
    expect(await sha256OfFileHex(dst), await sha256OfFileHex(src));
    expect(await filesIdentical(src, dst), isTrue);
    expect(partialLeftovers(rxDir), isEmpty);
  } finally {
    await tx.dispose(force: true);
    await rx.dispose(force: true);
    sandbox.deleteSync(recursive: true);
  }
}
