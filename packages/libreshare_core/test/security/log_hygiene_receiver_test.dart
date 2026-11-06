// Log hygiene, receiver half (Increment 3, work package P4).
// (The pairing half lives in `unit/pairing_test.dart`; PIN guard / server halves are P3's.)
//
// Sources: CLAUDE.md ("Never log file contents, keys, PINs or tunnel URL fragments"), LSP-1 5
// (Logging row), 4.3.5 (error messages carry no keys or PINs), docs/plans/inc3.md section 4.1
// `security/log_hygiene_test`: every Logger record at Level.ALL through session creation, SAS,
// wrong PIN, key change and a 10,000-file session, with sentinel values; none may appear; no
// 64-hex run (fingerprints are at most 16 hex = shortFp); no base64url run of 40+ characters;
// error envelopes carry none either; the existing `session $sid ...` line must shrink to an
// 8-character id prefix.
import 'dart:convert';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../helpers/p4_support.dart';

const String _pinSentinel = '424242';

void main() {
  final tx = p4Identity(kTxId);
  late P4Rig rig;
  late LogCapture logs;

  setUp(() {
    logs = LogCapture()..start();
  });
  tearDown(() async {
    await logs.stop();
    rig.dispose();
  });

  /// Runs [body], collecting every error envelope it triggers.
  Future<List<String>> collectEnvelopes(
    Iterable<Future<Object?> Function()> actions,
  ) async {
    final out = <String>[];
    for (final a in actions) {
      try {
        await a();
      } on LsException catch (e) {
        out.add(jsonEncode(e.toEnvelope()));
      }
    }
    return out;
  }

  // Harness twin: the scanner must be able to see each kind of leak, or the "clean" assertions
  // below prove nothing.
  group('the scanner sees what it must', () {
    test(
      '64-hex run, long base64url, full session id and sentinels are detected',
      () {
        rig = P4Rig();
        expect(p4Leaks('fp ${'A' * 64}'), contains('64-hex-run'));
        expect(p4Leaks('fp ${fpOf(tx)}'), contains('64-hex-run'));
        expect(p4Leaks('k ${'aB3_-' * 8}'), contains('base64url-run'));
        expect(
          p4Leaks('session 123e4567-e89b-42d3-a456-426614174000 x'),
          contains('full-session-id'),
        );
        expect(
          p4Leaks('pin $_pinSentinel', sentinels: {'pin': _pinSentinel}),
          contains('sentinel:pin'),
        );
        expect(p4Leaks('fp ${shortFp(fpOf(tx))} session 123e4567 ok'), isEmpty);
      },
    );

    test('LogCapture records at Level.ALL, including FINE', () async {
      rig = P4Rig();
      await rig.open(tx);
      expect(logs.records.where((r) => r.level == Level.FINE), isNotEmpty);
    });
  });

  // The existing receiver log line `session $sid from ...` becomes an 8-character prefix.
  test('the session id is logged as an 8-character prefix only', () async {
    rig = P4Rig();
    final st = await rig.open(tx);
    final sid = st.sessionId;
    expect(logs.text, isNot(contains(sid)));
    expect(
      logs.records.where((r) => r.message.contains(sid.substring(0, 8))),
      isNotEmpty,
      reason: 'the creation line is kept, with a short id',
    );
    expect(p4Leaks(logs.text), isNot(contains('full-session-id')));
  });

  test(
    'plaintext createSession logs the session id as a prefix as well',
    () async {
      rig = P4Rig(secure: false, autoAccept: true);
      final st = await rig.receiver.createSession(
        p4Request(tx),
        remoteAddress: '192.0.2.10',
      );
      expect(logs.text, isNot(contains(st.sessionId)));
      expect(
        logs.records.where(
          (r) => r.message.contains(st.sessionId.substring(0, 8)),
        ),
        isNotEmpty,
      );
    },
  );

  test('first contact: commit, both nonces, code, tokens, session id, fingerprints never appear', () async {
    rig = P4Rig();
    final sas = SasSender(tx, rig.rxFp);
    final st = await rig.open(tx, commit: sas.commit);
    expect(st.sas, isNotNull, reason: 'a SAS challenge is returned');
    final nr = st.sas!.nonce;
    await rig.receiver.revealSas(
      st.sessionId,
      nonce: sas.nonceB64,
      peer: peerOf(tx),
    );
    final code = rig.eventsOf<SasReady>().single.code;
    final accepted = await rig.receiver.accept(st.sessionId);
    final token = accepted.acceptedFiles['f0']!.token;

    final sentinels = {
      'commit': sas.commit,
      'Ns': sas.nonceB64,
      'Nr': nr,
      'Ns-hex': hexOf(sas.ns),
      'Nr-hex': hexOf(b64urlDecode(nr)),
      'token': token,
      'sessionId': st.sessionId,
      'fpTx': fpOf(tx),
      'fpRx': rig.rxFp,
      'code': code,
    };
    expect(p4Leaks(logs.text, sentinels: sentinels), isEmpty);
    // the code is six digits: also make sure it is not in there in display form
    expect(
      logs.text,
      isNot(contains('${code.substring(0, 3)} ${code.substring(3)}')),
    );
    expect(logs.records, isNotEmpty);
  });

  test(
    'commit mismatch and timeout paths log nothing sensitive either',
    () async {
      rig = P4Rig();
      final mitm = p4Identity('mitm-id');
      final sas = SasSender(
        tx,
        fpOf(mitm),
      ); // relayed: commit made for the wrong fingerprint
      final st = await rig.open(tx, commit: sas.commit);
      final envelopes = await collectEnvelopes([
        () => rig.receiver.revealSas(
          st.sessionId,
          nonce: sas.nonceB64,
          peer: peerOf(tx),
        ),
        () => rig.receiver.revealSas(
          st.sessionId,
          nonce: sas.nonceB64,
          peer: peerOf(tx),
        ),
      ]);
      expect(envelopes, hasLength(2));
      final sentinels = {
        'commit': sas.commit,
        'Ns': sas.nonceB64,
        'Nr': st.sas!.nonce,
        'sessionId': st.sessionId,
      };
      expect(p4Leaks(logs.text, sentinels: sentinels), isEmpty);
      for (final env in envelopes) {
        expect(p4Leaks(env, sentinels: sentinels), isEmpty);
      }
    },
  );

  // The PIN: a verifier that throws is the realistic failure (wrong PIN x N).
  test('wrong PIN: the PIN never reaches a log or an envelope; the correct one neither', () async {
    final pv = RecordingPinVerifier(
      failWith: LsException(LsErrorCode.pinInvalid, 'PIN invalid'),
    );
    rig = P4Rig(
      pinVerifier: pv,
      pin: const PinPolicy(mode: PinMode.fixed),
    );
    final envelopes = await collectEnvelopes([
      for (var i = 0; i < 5; i++) () => rig.open(tx, pin: _pinSentinel),
    ]);
    expect(envelopes, hasLength(5));
    pv.failWith = null;
    await rig.open(
      tx,
      pin: _pinSentinel,
    ); // the "correct" one is logged-clean too
    final sentinels = {'pin': _pinSentinel};
    expect(p4Leaks(logs.text, sentinels: sentinels), isEmpty);
    for (final env in envelopes) {
      expect(p4Leaks(env, sentinels: sentinels), isEmpty);
    }
    expect(
      pv.checks.first.pin,
      _pinSentinel,
      reason: 'the pin did reach the verifier',
    );
  });

  test('a verifier that throws a non-Ls error does not leak the PIN via the exception text', () async {
    // A bug in a PinVerifier must not make the receiver print the request.
    final pv = _ThrowingVerifier();
    rig = P4Rig(
      pinVerifier: pv,
      pin: const PinPolicy(mode: PinMode.fixed),
    );
    Object? thrown;
    try {
      await rig.open(tx, pin: _pinSentinel);
    } on Object catch (e) {
      thrown = e;
    }
    expect(
      thrown,
      isNotNull,
      reason: 'the failure is not swallowed into a success',
    );
    expect(p4Leaks(logs.text, sentinels: {'pin': _pinSentinel}), isEmpty);
  });

  test('key change: event carries the fingerprints, logs and envelope carry none of them', () async {
    rig = P4Rig();
    await rig.pinContact(tx, PeerTrust.trusted);
    final newKey = freshIdentity(kTxId);
    final envelopes = await collectEnvelopes([() => rig.open(newKey)]);
    expect(rig.eventsOf<PeerKeyChanged>(), hasLength(1));
    final sentinels = {'pinned': fpOf(tx), 'presented': fpOf(newKey)};
    expect(p4Leaks(logs.text, sentinels: sentinels), isEmpty);
    expect(p4Leaks(envelopes.single, sentinels: sentinels), isEmpty);
    // a log line about it is allowed, with short fingerprints at most
    for (final r in logs.records) {
      expect(RegExp(r'[0-9A-F]{17,}').hasMatch(r.message), isFalse);
    }
  });

  test('blocked, sender mismatch and 507 envelopes are clean', () async {
    rig = P4Rig();
    await rig.trust.block(fpOf(tx));
    final victim = p4Identity('victim-id');
    final envelopes = await collectEnvelopes([
      () => rig.open(tx),
      () => rig.receiver.createAuthenticatedSession(
        p4Request(tx, info: infoOf(tx, fingerprint: fpOf(victim))),
        remoteAddress: '192.0.2.10',
        peer: peerOf(tx),
      ),
      () {
        rig.free = 0;
        return rig.open(victim);
      },
    ]);
    expect(envelopes, hasLength(3));
    final sentinels = {'tx': fpOf(tx), 'victim': fpOf(victim)};
    for (final env in envelopes) {
      expect(p4Leaks(env, sentinels: sentinels), isEmpty);
    }
    expect(p4Leaks(logs.text, sentinels: sentinels), isEmpty);
  });

  // 10,000 files: a receiver that logs per file or dumps the manifest would put SHA-256 values
  // (64 hex) and a huge amount of text in the log.
  test('a 10,000-file session request logs a bounded, clean summary', () async {
    rig = P4Rig();
    final st = await rig.open(tx, fileCount: 10000);
    expect(st.status, TransferStatus.pending);
    expect(logs.records.length, lessThan(50));
    expect(logs.text.length, lessThan(20000));
    expect(p4Leaks(logs.text, sentinels: {'sessionId': st.sessionId}), isEmpty);
    // harness twin: the manifest does contain 64-hex values a dump would expose
    final req = p4Request(tx, fileCount: 3);
    expect(p4Leaks(jsonEncode(req.toJson())), contains('64-hex-run'));
  });

  test('a refused 10,000-file session (507) is just as quiet', () async {
    rig = P4Rig();
    rig.free = 0;
    await expectLs(
      rig.open(tx, fileCount: 10000),
      LsErrorCode.insufficientStorage,
    );
    expect(logs.records.length, lessThan(50));
    expect(p4Leaks(logs.text), isEmpty);
  });
}

class _ThrowingVerifier implements PinVerifier {
  @override
  bool get enforced => true;

  @override
  void check({
    required String remoteAddress,
    required String? pin,
    required bool exempt,
  }) => throw StateError('verifier bug');

  @override
  void consume() {}
}
