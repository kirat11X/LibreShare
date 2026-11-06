// P6a - END-TO-END log hygiene: every Logger record at Level.ALL across pairing, a SAS first contact,
// five wrong PINs, a key change, the goodbye, and a 10,000-file session request. Nothing secret may
// appear in a log line or in an error envelope.
//
// Spec: CLAUDE.md ("Never log file contents, keys, PINs or tunnel URL fragments"), docs/plans/inc3.md D6
// and section 4.1 `security/log_hygiene_test` (sentinels: PIN, pairing secret, private-key bytes,
// nonces, tokens, session ids; no 64-hex run, fingerprints <= 16 hex; no base64url run >= 40 chars;
// error envelopes contain none either), docs/plans/inc3-seams.md rule 2. The receiver-only version is
// security/log_hygiene_receiver_test (P4); this one runs the whole stack: engine, wiring, TLS server,
// secure client, FileSender, pairing, discovery.
//
// SPEC-GAP: file names are not treated as secrets here (the rules name content, keys, PINs and tunnel
// fragments); full session ids are (plan list), the allowed form is the 8-character prefix.
// NOTE (lower-layer finding to check): FileSender logs `session <full id> completed/failed` at info/
// warning level; if this test fails on a session id, that is the evidence.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/p6a_support.dart';

class _Capture {
  final List<LogRecord> records = [];
  StreamSubscription<LogRecord>? _sub;
  Level? _old;

  void start() {
    _old = Logger.root.level;
    Logger.root.level = Level.ALL;
    _sub = Logger.root.onRecord.listen(records.add);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    final old = _old;
    if (old != null) Logger.root.level = old;
  }

  /// Everything a log reader could see.
  String get text => records
      .map(
        (r) =>
            '${r.loggerName} ${r.level.name} ${r.message} '
            '${r.error ?? ''} ${r.stackTrace ?? ''}',
      )
      .join('\n');
}

/// Forwards to the real client and remembers every secret-looking value that crosses it, so the
/// test knows what to look for in the logs.
class _Recording implements SecurePeerClient {
  _Recording(this.inner);
  final ApiClient inner;
  final Set<String> sessionIds = {};
  final Set<String> nonces = {};
  final Set<String> tokens = {};
  final Set<String> commits = {};

  void _see(SessionStatus s) {
    sessionIds.add(s.sessionId);
    final n = s.sas?.nonce;
    if (n != null) nonces.add(n);
    for (final f in s.acceptedFiles.values) {
      tokens.add(f.token);
    }
  }

  @override
  String? get serverFingerprint => inner.serverFingerprint;

  @override
  Future<SessionStatus> createSession(SessionRequest r) async {
    final c = r.sasCommit;
    if (c != null) commits.add(c);
    final s = await inner.createSession(r);
    _see(s);
    return s;
  }

  @override
  Future<SessionStatus> revealSas(
    String sessionId, {
    required String nonce,
  }) async {
    nonces.add(nonce);
    final s = await inner.revealSas(sessionId, nonce: nonce);
    _see(s);
    return s;
  }

  @override
  Future<SessionStatus> waitSession(
    String sessionId, {
    int waitSeconds = 25,
  }) async {
    final s = await inner.waitSession(sessionId, waitSeconds: waitSeconds);
    _see(s);
    return s;
  }

  @override
  Future<DeviceInfo> info() => inner.info();
  @override
  Future<DeviceInfo> register(DeviceInfo self) => inner.register(self);
  @override
  Future<PairResponse> pair(PairRequest request) => inner.pair(request);
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

final RegExp _word = RegExp(r'[A-Za-z0-9_-]{16,}');

/// Names every kind of leak the hygiene rules forbid in [text]. Empty = clean.
///  * [exact]: literal secrets (private-key body, pairing secret) found as substrings.
///  * [pins]: six-digit PINs found as whole numbers.
///  * [words]: values (nonces, tokens, session ids, commitments) found as whole words.
List<String> leaks(
  String text, {
  Map<String, String> exact = const {},
  Map<String, String> pins = const {},
  Map<String, Set<String>> words = const {},
}) {
  final out = <String>[];
  exact.forEach((label, v) {
    if (v.isNotEmpty && text.contains(v)) out.add('secret:$label');
  });
  pins.forEach((label, v) {
    if (RegExp('(?<![0-9A-Za-z])${RegExp.escape(v)}(?![0-9A-Za-z])')
        .hasMatch(text)) {
      out.add('pin:$label');
    }
  });
  final seen = {for (final m in _word.allMatches(text)) m.group(0)!};
  words.forEach((label, set) {
    if (seen.any(set.contains)) out.add('value:$label');
  });
  if (text.contains('PRIVATE KEY')) out.add('private-key-header');
  if (RegExp(r'[0-9A-Fa-f]{64}').hasMatch(text)) out.add('64-hex-run');
  if (RegExp(r'[A-Za-z0-9_-]{40,}').hasMatch(text)) out.add('base64url-run');
  return out;
}

Future<void> main() async {
  final skip = await p6aSkipReason();

  // The detector itself must be able to fail (every kind of leak, and a clean text).
  group('the leak detector', () {
    test('finds each kind of leak and passes clean text', () {
      expect(leaks('hello fp=0123456789ABCDEF'), isEmpty);
      expect(leaks('pin 424242 here', pins: {'pin': '424242'}), ['pin:pin']);
      expect(
        leaks('pin 1424242 here', pins: {'pin': '424242'}),
        isEmpty,
        reason: 'part of a longer number is not the PIN',
      );
      expect(leaks('x ${'A' * 64} y'), contains('64-hex-run'));
      expect(leaks('x ${'a' * 40} y'), contains('base64url-run'));
      expect(
        leaks('-----BEGIN PRIVATE KEY-----'),
        contains('private-key-header'),
      );
      expect(leaks('s=SECRETSECRET', exact: {'secret': 'SECRETSECRET'}), [
        'secret:secret',
      ]);
      expect(
        leaks(
          'token abcdefghijklmnopqrstuv end',
          words: {
            't': {'abcdefghijklmnopqrstuv'},
          },
        ),
        ['value:t'],
      );
      expect(
        leaks(
          'token abcdefghijklmnopqrstuvX end',
          words: {
            't': {'abcdefghijklmnopqrstuv'},
          },
        ),
        isEmpty,
      );
    });
  });

  group('the whole stack', () {
    late Directory sandbox;
    late P6aRig rig;
    final cap = _Capture();

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('ls_p6a_log_');
      rig = P6aRig(sandbox);
      cap.records.clear();
      cap.start();
    });
    tearDown(() async {
      await cap.stop();
      await rig.dispose();
      sandbox.deleteSync(recursive: true);
    });

    test(
      'pair, SAS send, five wrong PINs, key change, bye and a 10,000-file request leave no secret in any log line or error envelope',
      () async {
        const pin = '424242';
        const wrongPin = '707070';

        final r = await rig.start(
          'Recv',
          discovery: true,
          pinPolicy: const PinPolicy(mode: PinMode.fixed),
          pin: pin,
        );
        final o = await rig.start('Observer', discovery: true);
        final paired = await rig.start('Paired');
        final s = await rig.start('Sender');
        final h = await rig.start('Harvest');
        final x = await rig.start('Attacker');
        final k = await rig.start(
          'Sender', // same device id as `s`, another key
          deviceId: s.deviceId,
          idDir: Directory(p.join(sandbox.path, 'id-sender-new')),
        );
        final nodes = [r, o, paired, s, h, x, k];
        final envelopes = <String>[];
        final sessionIds = <String>{};
        final nonces = <String>{};
        final tokens = <String>{};
        final commits = <String>{};
        var counter = 0;
        File src(int size) => writeRandomFile(
          Directory(p.join(sandbox.path, 'src')),
          'f${counter++}.bin',
          size,
          seed: counter,
        );

        Future<void> envelope(Future<Object?> Function() call) async {
          try {
            await call();
          } on LsException catch (e) {
            envelopes.add('${e.code.wire}: ${e.message}');
          }
        }

        // --- pairing
        final uri = Uri.parse(r.engine.createPairInvite());
        final pairingSecret = uri.queryParameters['s']!;
        final redeem = paired.engine.redeemPairInvite(uri.toString());
        await until(
          () => r.engine.pairing.pendingPrompt != null,
          what: 'pair prompt',
        );
        r.engine.pairing.decide(accept: true);
        expect(await redeem, isTrue);

        // --- SAS send through the engine (first contact, PIN needed)
        final ok = await sendTo(s, r, [src(1500)], pin: pin);
        expect(ok.isSuccess, isTrue, reason: '$ok');

        // --- the same flow through a recording client to learn nonces, tokens and session ids
        final rec = _Recording(
          ApiClient(host: r.ip, port: r.port, security: h.wiring!.config),
        );
        final harvest = await FileSender(
          client: rec,
          self: h.engine.deviceInfo,
          security: h.wiring!.config,
          pin: pin,
        ).send([src(2500)]);
        expect(harvest.isSuccess, isTrue, reason: '$harvest');
        rec.close();
        sessionIds.addAll(rec.sessionIds);
        nonces.addAll(rec.nonces);
        tokens.addAll(rec.tokens);
        commits.addAll(rec.commits);
        expect(
          rec.nonces.length,
          greaterThanOrEqualTo(2),
          reason: 'twin: Ns and Nr were seen',
        );
        expect(rec.tokens, isNotEmpty);

        // --- a 10,000-file session request from a known sender (S pinned R at its first contact)
        final bigFiles = [
          for (var i = 0; i < kMaxFilesPerSession; i++)
            FileItem(
              fileId: 'f$i',
              fileName: 'file-$i.bin',
              size: 1,
              chunkCount: 1,
            ),
        ];
        final sClient = _Recording(
          ApiClient(
            host: r.ip,
            port: r.port,
            security: s.wiring!.config,
            expectedFingerprint: r.fp,
            requestTimeout: const Duration(seconds: 60),
          ),
        );
        final big = await sClient.createSession(
          SessionRequest(
            sender: s.engine.deviceInfo,
            pin: pin,
            files: bigFiles,
            totalSize: bigFiles.length,
          ),
        );
        expect(
          big.acceptedFiles.length,
          kMaxFilesPerSession,
          reason: 'twin: the big request was served',
        );
        await sClient.cancel(big.sessionId);
        sClient.close();
        sessionIds.addAll(sClient.sessionIds);
        tokens.addAll(sClient.tokens);

        // --- key change: another key behind a known device id
        final changed = await sendTo(k, r, [src(10)], pin: pin);
        expect(changed.isSuccess, isFalse);
        final kClient = ApiClient(
          host: r.ip,
          port: r.port,
          security: k.wiring!.config,
          expectedFingerprint: r.fp,
        );
        await envelope(
          () => kClient.createSession(
            SessionRequest(
              sender: k.engine.deviceInfo,
              pin: pin,
              files: const [
                FileItem(
                  fileId: 'f1',
                  fileName: 'a.bin',
                  size: 1,
                  chunkCount: 1,
                ),
              ],
              totalSize: 1,
            ),
          ),
        );
        kClient.close();
        expect(
          envelopes.any((e) => e.startsWith('KEY_CHANGED')),
          isTrue,
          reason: 'twin: the key change was refused with its envelope',
        );

        // --- five wrong PINs (two through the engine, three raw so the envelopes can be read), then
        // the right one: blocked.
        for (var i = 0; i < 2; i++) {
          final res = await sendTo(x, r, [src(10)], pin: wrongPin);
          expect(res.isSuccess, isFalse);
        }
        final xi = x.engine.deviceInfo;
        final xClient = ApiClient(
          host: r.ip,
          port: r.port,
          security: x.wiring!.config,
          expectedFingerprint: r.fp,
        );
        SessionRequest probe(String? withPin) => SessionRequest(
          sender: xi,
          pin: withPin,
          files: const [
            FileItem(fileId: 'f1', fileName: 'a.bin', size: 1, chunkCount: 1),
          ],
          totalSize: 1,
        );
        await envelope(() => xClient.createSession(probe(null)));
        for (var i = 0; i < 3; i++) {
          await envelope(() => xClient.createSession(probe(wrongPin)));
        }
        await envelope(() => xClient.createSession(probe(pin)));
        xClient.close();
        expect(
          envelopes.where((e) => e.startsWith('PIN_INVALID')),
          hasLength(greaterThanOrEqualTo(1)),
          reason: 'twin: the harness captured wrong-PIN envelopes',
        );
        expect(
          envelopes.any((e) => e.startsWith('BLOCKED')),
          isTrue,
          reason: 'the sixth try, with the right PIN, is blocked',
        );

        // --- goodbye: the observer must have learned R first
        await until(
          () => o.engine.currentDevices.any((d) => d.id == r.deviceId),
          what: 'observer lists R',
        );
        await settle(300);
        await r.engine.receive.turnOff();
        await until(
          () => !o.engine.currentDevices.any((d) => d.id == r.deviceId),
          timeout: const Duration(seconds: 2),
          what: 'goodbye processed',
        );

        // --- collect every session id the engines saw
        for (final n in nodes) {
          for (final e in n.events.all) {
            if (e is SessionCreated) sessionIds.add(e.sessionId);
            if (e is SessionFinished && e.sessionId.isNotEmpty) {
              sessionIds.add(e.sessionId);
            }
          }
        }
        await settle();
        await cap.stop();

        final keyBodies = {
          for (final n in nodes)
            'key-${n.name}-${n.deviceId.substring(0, 4)}': pemBody(
              n.wiring!.identity.privateKeyPem(),
            ),
        };
        final fullFingerprints = {for (final n in nodes) n.fp};
        final text = cap.text;
        final all = '$text\n${envelopes.join('\n')}';

        expect(
          cap.records.length,
          greaterThan(20),
          reason: 'twin: the capture saw the run',
        );
        expect(
          text,
          contains('PairingService'),
          reason: 'twin: pairing logged something',
        );

        final found = leaks(
          all,
          exact: {'pairing-secret': pairingSecret, ...keyBodies},
          pins: {'pin': pin, 'wrong-pin': wrongPin},
          words: {
            'nonce': nonces,
            'token': tokens,
            'session-id': sessionIds,
            'sas-commit': commits,
          },
        );
        expect(found, isEmpty, reason: 'leaks in logs or envelopes: $found');
        for (final fp in fullFingerprints) {
          expect(
            all.contains(fp),
            isFalse,
            reason: 'a full fingerprint was logged',
          );
        }
        // Fingerprints may appear shortened: 16 hex is allowed (and ours do, e.g. "paired fp=").
        expect(
          all,
          matches(RegExp(r'fp=[0-9A-F]{16}\b')),
          reason: 'twin: short fingerprints do appear, so the 64-hex rule has something to guard',
        );
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
}
