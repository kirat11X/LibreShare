// P6a - the FR-16 attack set of integration/two_engine_test, replayed over TLS (pinned receiver and
// first contact through the SAS flow), with the plaintext profile as the control.
//
// Spec: FR-16 / NFR-04, LSP-1 4.4 and the sanitizer rules (a hostile fileName is neutralised and the
// result stays inside the download directory; a relativePath with a `..` segment is refused with
// PROTOCOL_ERROR and nothing is written; an absolute relativePath is re-rooted inside the dir), docs/plans/inc3.md section 4 row FR-16
// (`integration/path_traversal_secure_test`: `../../etc/passwd` and a `..` relativePath through TLS+SAS).
//
// The hostile manifests are produced by a PeerClient decorator below the FileSender, exactly like the
// Inc 1 test, so the attack travels through the real secure ApiClient, ApiServer, receiver and engine.
@TestOn('vm')
library;

import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/p6a_support.dart';

/// Forwards to [inner] but rewrites the manifest of `createSession`.
class RewritingSecureClient implements SecurePeerClient {
  RewritingSecureClient(this.inner, this.rewrite);

  final ApiClient inner;
  final FileItem Function(int index, FileItem item) rewrite;

  @override
  String? get serverFingerprint => inner.serverFingerprint;
  @override
  Future<SessionStatus> revealSas(String sessionId, {required String nonce}) =>
      inner.revealSas(sessionId, nonce: nonce);
  @override
  Future<PairResponse> pair(PairRequest request) => inner.pair(request);

  @override
  Future<SessionStatus> createSession(SessionRequest r) => inner.createSession(
    SessionRequest(
      sender: r.sender,
      pin: r.pin,
      chunkSize: r.chunkSize,
      sasCommit: r.sasCommit,
      files: [for (var i = 0; i < r.files.length; i++) rewrite(i, r.files[i])],
      totalSize: r.totalSize,
      tunnelOffer: r.tunnelOffer,
    ),
  );

  @override
  Future<DeviceInfo> info() => inner.info();
  @override
  Future<DeviceInfo> register(DeviceInfo self) => inner.register(self);
  @override
  Future<SessionStatus> waitSession(String sessionId, {int waitSeconds = 25}) =>
      inner.waitSession(sessionId, waitSeconds: waitSeconds);
  @override
  Future<FileState> fileState(
    String sessionId,
    String fileId, {
    required String token,
  }) => inner.fileState(sessionId, fileId, token: token);
  @override
  Future<void> putChunk(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body, {
    required int length,
    required String chunkSha256,
    required String token,
  }) => inner.putChunk(
    sessionId,
    fileId,
    index,
    body,
    length: length,
    chunkSha256: chunkSha256,
    token: token,
  );
  @override
  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  }) => inner.completeFile(sessionId, fileId, token: token, sha256: sha256);
  @override
  Future<SessionStatus> finish(String sessionId) => inner.finish(sessionId);
  @override
  Future<void> cancel(String sessionId) => inner.cancel(sessionId);
  @override
  void close() => inner.close();
}

FileItem withNames(FileItem i, {String? fileName, String? relativePath}) =>
    FileItem(
      fileId: i.fileId,
      fileName: fileName ?? i.fileName,
      relativePath: relativePath ?? i.relativePath,
      size: i.size,
      chunkCount: i.chunkCount,
      mime: i.mime,
      sha256: i.sha256,
      modified: i.modified,
    );

Future<void> main() async {
  final skip = await p6aSkipReason();
  late Directory sandbox;
  late P6aRig rig;
  var counter = 0;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ls_p6a_trav_');
    rig = P6aRig(sandbox);
  });
  tearDown(() async {
    await rig.dispose();
    sandbox.deleteSync(recursive: true);
  });

  File source(String name, int size, {int seed = 1}) => writeRandomFile(
    Directory(p.join(sandbox.path, 'src-${counter++}')),
    name,
    size,
    seed: seed,
  );

  bool isFixture(String path) {
    final first = p.split(p.relative(path, from: sandbox.path)).first;
    return first.startsWith('src-') || first.startsWith('id-');
  }

  /// Every regular file below the sandbox that is neither a fixture (`src-*`, `id-*`) nor inside
  /// [allowed].
  List<String> filesOutside(Directory allowed) => [
    for (final e in sandbox.listSync(recursive: true, followLinks: false))
      if (e is File && !p.isWithin(allowed.path, e.path) && !isFixture(e.path))
        e.path,
  ];

  /// Sends [files] from [from] to [to] with the manifest rewritten by [rewrite]. [pinned] = the
  /// sender already pins the receiver (no SAS); otherwise first contact with a SAS comparison.
  Future<SendResult> sendRewritten(
    P6aNode from,
    P6aNode to,
    List<File> files,
    FileItem Function(int, FileItem) rewrite, {
    required bool pinned,
  }) async {
    final security = from.wiring?.config ?? const SecurityConfig.plaintext();
    final api = ApiClient(
      host: to.ip,
      port: to.port,
      security: security,
      expectedFingerprint: from.isSecure && pinned ? to.fp : null,
    );
    try {
      return await FileSender(
        client: from.isSecure
            ? RewritingSecureClient(api, rewrite)
            : _RewritingPlainClient(api, rewrite),
        self: from.engine.deviceInfo,
        security: security,
        pinnedReceiverFingerprint: from.isSecure && pinned ? to.fp : null,
      ).send(files);
    } finally {
      api.close();
    }
  }

  const modes = <(String, bool, bool)>[
    ('plaintext profile (control)', false, true),
    ('TLS, pinned receiver', true, true),
    ('TLS, first contact with SAS', true, false),
  ];

  for (final (label, secure, pinned) in modes) {
    group('path traversal over $label', () {
      late P6aNode a;
      late P6aNode b;

      setUp(() async {
        a = await rig.start('Alice', secure: secure);
        b = await rig.start('Bob', secure: secure);
      });

      test(
        'fileName ../../evil.txt (and variants) lands inside the download dir',
        () async {
          final tag = DateTime.now().microsecondsSinceEpoch;
          final absolute = '/tmp/ls-p6a-evil-$tag.txt';
          final deep = '../../../../../../../../tmp/ls-p6a-deep-$tag.txt';
          final files = [
            source('t1.bin', 11, seed: 61),
            source('t2.bin', 22, seed: 62),
            source('t3.bin', 33, seed: 63),
            source('t4.bin', 44, seed: 64),
            source('t5.bin', 55, seed: 65),
          ];
          final hostile = [
            '../../evil.txt',
            r'..\..\evil2.txt',
            absolute,
            deep,
            '../../../../../../../../etc/passwd',
          ];
          final res = await sendRewritten(
            a,
            b,
            files,
            (i, item) => withNames(item, fileName: hostile[i]),
            pinned: pinned,
          );
          expect(res.isSuccess, isTrue, reason: '$res');

          final saved = b.events.of<FileSaved>();
          expect(saved, hasLength(files.length));
          for (var i = 0; i < files.length; i++) {
            expect(
              p.isWithin(b.rx.path, saved[i].path),
              isTrue,
              reason: '${saved[i].path} escaped ${b.rx.path}',
            );
            await expectSameFile(files[i], File(saved[i].path));
          }
          expect(
            b.rx.listSync().map((e) => p.basename(e.path)),
            containsAll(['evil.txt', 'evil2.txt', 'passwd']),
          );
          expect(filesOutside(b.rx), isEmpty);
          expect(File(absolute).existsSync(), isFalse);
          expect(File('/tmp/ls-p6a-deep-$tag.txt').existsSync(), isFalse);
          expect(leftovers(b.rx), isEmpty);
          expect(
            b.sasCodes(outgoing: false).length,
            secure && !pinned ? 1 : 0,
            reason: 'the receiver showed a SAS exactly in the first-contact variant (the rewriting sender bypasses the engine events)',
          );
        },
        skip: skip,
      );

      test('a relativePath with a .. segment is refused with PROTOCOL_ERROR and nothing is written', () async {
        for (final bad in [
          '../../evil.txt',
          'photos/../../evil.txt',
          r'..\x',
        ]) {
          final f = source('rel-${bad.hashCode.abs()}.bin', 10, seed: 65);
          final res = await sendRewritten(
            a,
            b,
            [f],
            (i, item) => withNames(item, relativePath: bad),
            pinned: pinned,
          );
          expect(res.status, TransferStatus.failed, reason: '$bad: $res');
          expect(res.failureReason, FailureReason.protocolError, reason: bad);
        }
        expect(b.rx.existsSync() ? b.rx.listSync() : const [], isEmpty);
        expect(filesOutside(b.rx), isEmpty);
        expect(b.events.of<FileSaved>(), isEmpty);
      }, skip: skip);

      // The sanitizer (unit/filename_sanitizer_test 'absolute relativePath is re-rooted inside the
      // dir') drops the leading separator or UNC prefix: the segments become folders INSIDE the
      // download dir. Only `..` is refused.
      test('an absolute relativePath is re-rooted: saved strictly inside the download dir, byte-identical', () async {
        final cases = <(String, List<String>)>[
          ('/etc/cron.d/evil', ['etc', 'cron.d', 'evil']),
          (r'\\server\share\x', ['server', 'share', 'x']),
        ];
        for (final (rel, segments) in cases) {
          final f = source('abs-${segments.first}.bin', 1500, seed: 67);
          final res = await sendRewritten(
            a,
            b,
            [f],
            (i, item) => withNames(item, relativePath: rel),
            pinned: pinned,
          );
          expect(res.isSuccess, isTrue, reason: '$rel: $res');
          final target = File(
            p.joinAll([b.rx.path, ...segments, p.basename(f.path)]),
          );
          expect(p.isWithin(b.rx.path, target.path), isTrue);
          await expectSameFile(f, target);
        }
        final saved = b.events.of<FileSaved>();
        expect(saved, hasLength(cases.length));
        for (final e in saved) {
          expect(p.isWithin(b.rx.path, e.path), isTrue, reason: e.path);
        }
        expect(filesOutside(b.rx), isEmpty);
        expect(File('/etc/cron.d/abs-etc.bin').existsSync(), isFalse);
        expect(leftovers(b.rx), isEmpty);
      }, skip: skip);

      test('an honest relativePath creates its folders inside the download dir (control)', () async {
        final f = source('deep.bin', 2000, seed: 66);
        final res = await sendRewritten(
          a,
          b,
          [f],
          (i, item) => withNames(item, relativePath: 'photos/2024/trip'),
          pinned: pinned,
        );
        expect(res.isSuccess, isTrue, reason: '$res');
        await expectSameFile(
          f,
          File(p.join(b.rx.path, 'photos', '2024', 'trip', 'deep.bin')),
        );
        expect(filesOutside(b.rx), isEmpty);
      }, skip: skip);
    });
  }
}

/// The plaintext twin of [RewritingSecureClient] (control group only).
class _RewritingPlainClient implements PeerClient {
  _RewritingPlainClient(this.inner, this.rewrite);
  final ApiClient inner;
  final FileItem Function(int index, FileItem item) rewrite;

  @override
  Future<SessionStatus> createSession(SessionRequest r) => inner.createSession(
    SessionRequest(
      sender: r.sender,
      pin: r.pin,
      chunkSize: r.chunkSize,
      files: [for (var i = 0; i < r.files.length; i++) rewrite(i, r.files[i])],
      totalSize: r.totalSize,
      tunnelOffer: r.tunnelOffer,
    ),
  );
  @override
  Future<DeviceInfo> info() => inner.info();
  @override
  Future<DeviceInfo> register(DeviceInfo self) => inner.register(self);
  @override
  Future<SessionStatus> waitSession(String sessionId, {int waitSeconds = 25}) =>
      inner.waitSession(sessionId, waitSeconds: waitSeconds);
  @override
  Future<FileState> fileState(
    String sessionId,
    String fileId, {
    required String token,
  }) => inner.fileState(sessionId, fileId, token: token);
  @override
  Future<void> putChunk(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body, {
    required int length,
    required String chunkSha256,
    required String token,
  }) => inner.putChunk(
    sessionId,
    fileId,
    index,
    body,
    length: length,
    chunkSha256: chunkSha256,
    token: token,
  );
  @override
  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  }) => inner.completeFile(sessionId, fileId, token: token, sha256: sha256);
  @override
  Future<SessionStatus> finish(String sessionId) => inner.finish(sessionId);
  @override
  Future<void> cancel(String sessionId) => inner.cancel(sessionId);
  @override
  void close() => inner.close();
}
