// PIN shape (LSP-1 5.2, 4.3.4 secure order step 5 "shape", 4.3.5 BAD_REQUEST, schema
// session-request `pin`: `^[0-9]{6}$`).
//
// Rule under test: a `pin` that is PRESENT but not exactly six ASCII digits is answered
// 400 BAD_REQUEST, is never compared with the real PIN and therefore costs no strike. An ABSENT
// (or JSON null) pin is not malformed: 401 PIN_REQUIRED when a PIN is enforced, fine otherwise.
// The PIN text never appears in the error body or in a log record.
//
// Two layers, same expectations:
//  * the real secure ApiServer over TLS with a real PinGuard behind a recording handler
//    (test/helpers/p3_secure_rig.dart, p3v_support.dart; the 400 must come from the HTTP layer
//    or from whatever the handler does, the observable contract is the same);
//  * FileReceiver.createAuthenticatedSession with a real PinGuard (test/helpers/p4_support.dart).
// The plaintext profile enforces no PIN: a characterisation block pins down what it does today.
import 'dart:convert';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p3_secure_rig.dart';
import '../helpers/p3v_support.dart';
import '../helpers/p4_support.dart';

const String _realPin = '482913';
const PinPolicy _fixed = PinPolicy(mode: PinMode.fixed);

/// Present-but-malformed string PINs.
final Map<String, String> _badStrings = {
  'empty string': '',
  'five digits': '48291',
  'seven digits': '4829135',
  'one digit': '4',
  'letters': 'abcdef',
  'digits and a letter': '48291a',
  'hex-looking': '0x1234',
  'Arabic-Indic digits': '٤٨٢٩١٣',
  'fullwidth digits': '４８２９１３',
  'leading space': ' 482913',
  'trailing space': '482913 ',
  'inner space': '482 913',
  'trailing newline': '482913\n',
  'leading plus': '+48291',
  'minus sign': '-48291',
  'only spaces': '      ',
  'tab': '\t482913',
  'ten kilobytes': 'x' * 10240,
  'ten kilobytes of digits': '1' * 10240,
};

/// Present-but-malformed non-string JSON values.
final Map<String, Object?> _badJson = {
  'number': 482913,
  'float': 482913.0,
  'boolean': true,
  'array': ['482913'],
  'object': {'pin': '482913'},
};

/// A PIN value that is long and distinctive enough for "never appears in a body or log".
bool _traceable(String s) => s.trim().length >= 5 && s != _realPin;

// ============================================================ layer 1: ApiServer

List<int> _apiBody(P3Peer who, {Object? pin, bool omit = false}) {
  final map = SessionRequest(
    sender: who.info(),
    files: const [
      FileItem(fileId: 'f0', fileName: 'a.bin', size: 1, chunkCount: 1),
    ],
    totalSize: 1,
  ).toJson();
  map.remove('pin');
  if (!omit) map['pin'] = pin;
  return utf8.encode(jsonEncode(map));
}

void _apiTests() {
  late PinGuard guard;
  late P3Rig rig;
  late P3LogCapture logs;
  var bruteForce = 0;

  Future<void> start({PinPolicy policy = _fixed}) async {
    bruteForce = 0;
    guard = PinGuard(
      policy: policy,
      pin: policy.enabled ? _realPin : null,
      onBruteForce: () => bruteForce++,
    );
    rig = await P3Rig.start(handler: P3vPinHandler(guard));
  }

  setUp(() => logs = P3LogCapture());
  tearDown(() async {
    await rig.stop();
    await logs.close();
  });

  Future<P3Res> send(Object? pin, {bool omit = false}) => rig.request(
    'POST',
    '/sessions',
    body: _apiBody(p3Alice, pin: pin, omit: omit),
    headers: {'content-type': 'application/json'},
    signAs: p3Alice,
  );

  void expectBadRequest(P3Res r, String what) {
    expect(r.status, 400, reason: '$what: ${r.text}');
    expect(r.error['code'], 'BAD_REQUEST', reason: what);
    expect(r.error['retryable'], false, reason: what);
  }

  group('secure ApiServer: malformed pin is 400 BAD_REQUEST', () {
    setUp(() => start());

    for (final e in _badStrings.entries) {
      test('pin ${e.key}', () async {
        final r = await send(e.value);
        expectBadRequest(r, e.key);
        if (_traceable(e.value)) {
          expect(r.text, isNot(contains(e.value)), reason: 'echoed in body');
          expect(logs.all, isNot(contains(e.value)), reason: 'logged');
        }
        // No strike: the guard still accepts the real PIN from this source afterwards.
        expect((await send(_realPin)).status, 202);
      });
    }

    for (final e in _badJson.entries) {
      test('non-string json value (${e.key}) is 400', () async {
        expectBadRequest(await send(e.value), e.key);
        expect((await send(_realPin)).status, 202);
      });
    }

    test(
      'the real PIN with one digit changed is a wrong PIN, not a shape error',
      () async {
        final r = await send('482914');
        expect(r.status, 401);
        expect(r.error['code'], 'PIN_INVALID');
      },
    );

    test(
      'the error body and the logs never contain the real PIN either',
      () async {
        await send('48291');
        await send(_realPin);
        expect(logs.all, isNot(contains(_realPin)));
      },
    );
  });

  group('secure ApiServer: malformed pins cost no strike', () {
    test('five malformed then five wrong-format-correct PINs: normal 5-strike threshold', () async {
      await start();
      for (var i = 0; i < 5; i++) {
        expectBadRequest(await send('${i}2345'), 'malformed #$i');
      }
      final wrong = p3vWrongPin(_realPin);
      for (var i = 1; i <= 5; i++) {
        final r = await send(wrong);
        expect(r.status, 401, reason: 'wrong PIN #$i');
        expect(r.error['code'], 'PIN_INVALID', reason: 'wrong PIN #$i');
      }
      // The fifth strike blocks the source: even the correct PIN is refused now.
      final blocked = await send(_realPin);
      expect(blocked.status, 403);
      expect(blocked.error['code'], 'BLOCKED');
      expect(p3vRetryAfterSeconds(blocked), isNotNull);
    });

    test(
      'five malformed then four wrong PINs: the correct PIN still works',
      () async {
        await start();
        for (var i = 0; i < 5; i++) {
          expectBadRequest(await send('abcde$i'), 'malformed #$i');
        }
        for (var i = 1; i <= 4; i++) {
          expect(
            (await send(p3vWrongPin(_realPin))).error['code'],
            'PIN_INVALID',
          );
        }
        expect((await send(_realPin)).status, 202);
      },
    );

    test('a flood of malformed pins from one IP neither blocks it nor locks the PINs', () async {
      await start();
      for (var i = 0; i < 40; i++) {
        expectBadRequest(await send('x$i'), 'malformed #$i');
      }
      expect((await send(_realPin)).status, 202);
      expect(bruteForce, 0, reason: 'the brute-force hook must not fire');
      expect(guard.currentPin, _realPin, reason: 'the PIN must not be rotated');
    });

    test(
      'malformed pins do not count towards the global lock either',
      () async {
        await start();
        // 24 genuine strikes from other sources would be needed to get near the lock; here only the
        // malformed ones are sent: the lock threshold (25) must stay out of reach.
        for (var i = 0; i < 30; i++) {
          expectBadRequest(await send(''), 'malformed #$i');
        }
        for (var i = 0; i < 4; i++) {
          await send(p3vWrongPin(_realPin));
        }
        expect((await send(_realPin)).status, 202);
      },
    );
  });

  group('secure ApiServer: absent pin', () {
    test('absent member with a PIN enforced is 401 PIN_REQUIRED', () async {
      await start();
      final r = await send(null, omit: true);
      expect(r.status, 401);
      expect(r.error['code'], 'PIN_REQUIRED');
    });

    test('JSON null with a PIN enforced is 401 PIN_REQUIRED', () async {
      await start();
      final r = await send(null);
      expect(r.status, 401);
      expect(r.error['code'], 'PIN_REQUIRED');
    });

    test('absent PIN requests cost no strike', () async {
      await start();
      for (var i = 0; i < 12; i++) {
        expect((await send(null, omit: true)).error['code'], 'PIN_REQUIRED');
      }
      expect((await send(_realPin)).status, 202);
    });

    test('absent pin with no PIN enforced is accepted', () async {
      await start(policy: const PinPolicy.off());
      expect((await send(null, omit: true)).status, 202);
      expect((await send(null)).status, 202);
    });

    test('a well-formed pin with no PIN enforced is accepted', () async {
      await start(policy: const PinPolicy.off());
      expect((await send('123456')).status, 202);
    });

    test(
      'a malformed pin with no PIN enforced is still a shape error (400)',
      () async {
        await start(policy: const PinPolicy.off());
        expectBadRequest(await send('12345'), 'five digits, PIN off');
        expectBadRequest(await send(''), 'empty, PIN off');
      },
    );
  });
}

// ============================================================ layer 2: FileReceiver

void _receiverTests() {
  late PinGuard guard;
  late P4Rig rig;
  late LogCapture logs;
  late KeyIdentity alice;
  var bruteForce = 0;

  setUpAll(() => alice = p4Identity('pin-shape-alice'));

  void start({PinPolicy policy = _fixed}) {
    bruteForce = 0;
    guard = PinGuard(
      policy: policy,
      pin: policy.enabled ? _realPin : null,
      onBruteForce: () => bruteForce++,
    );
    rig = P4Rig(pin: policy, pinVerifier: guard);
  }

  setUp(() {
    logs = LogCapture()..start();
  });
  tearDown(() async {
    rig.dispose();
    await logs.stop();
  });

  Future<SessionStatus> open(String? pin) => rig.open(alice, pin: pin);

  group('FileReceiver: malformed pin is BAD_REQUEST', () {
    setUp(() => start());

    for (final e in _badStrings.entries) {
      test('pin ${e.key}', () async {
        final err = await expectLs(open(e.value), LsErrorCode.badRequest);
        if (_traceable(e.value)) {
          expect(err.message, isNot(contains(e.value)));
          expect('$err', isNot(contains(e.value)));
          expect(logs.text, isNot(contains(e.value)));
        }
        final ok = await open(_realPin);
        expect(ok.status, TransferStatus.pending);
      });
    }

    test('the exception carries a non-retryable BAD_REQUEST', () async {
      final err = await expectLs(open('12345'), LsErrorCode.badRequest);
      expect(err.retryable, isFalse);
      expect(err.httpStatus, 400);
    });
  });

  group('FileReceiver: malformed pins cost no strike', () {
    test(
      'five malformed then five wrong PINs: normal 5-strike threshold',
      () async {
        start();
        for (var i = 0; i < 5; i++) {
          await expectLs(open('${i}2345'), LsErrorCode.badRequest);
        }
        final wrong = p3vWrongPin(_realPin);
        for (var i = 1; i <= 5; i++) {
          await expectLs(open(wrong), LsErrorCode.pinInvalid);
        }
        final blocked = await expectLs(open(_realPin), LsErrorCode.blocked);
        expect(blocked.retryAfter, isNotNull);
      },
    );

    test(
      'five malformed then four wrong PINs: the correct PIN still works',
      () async {
        start();
        for (var i = 0; i < 5; i++) {
          await expectLs(open('abcde$i'), LsErrorCode.badRequest);
        }
        for (var i = 1; i <= 4; i++) {
          await expectLs(open(p3vWrongPin(_realPin)), LsErrorCode.pinInvalid);
        }
        expect((await open(_realPin)).status, TransferStatus.pending);
      },
    );

    test(
      'a flood of malformed pins neither blocks the IP nor locks the PINs',
      () async {
        start();
        for (var i = 0; i < 40; i++) {
          await expectLs(open('x$i'), LsErrorCode.badRequest);
        }
        expect((await open(_realPin)).status, TransferStatus.pending);
        expect(bruteForce, 0);
        expect(guard.currentPin, _realPin);
      },
    );

    test('a malformed pin never reaches the PinVerifier', () async {
      final recorder = RecordingPinVerifier();
      rig = P4Rig(pin: _fixed, pinVerifier: recorder);
      for (final v in ['', '12345', '1234567', 'abcdef', '٤٨٢٩١٣']) {
        await expectLs(open(v), LsErrorCode.badRequest);
      }
      expect(recorder.checks, isEmpty);
      expect(recorder.consumed, 0);
    });
  });

  group('FileReceiver: absent pin', () {
    test(
      'absent with a PIN enforced is PIN_REQUIRED and costs no strike',
      () async {
        start();
        for (var i = 0; i < 12; i++) {
          await expectLs(open(null), LsErrorCode.pinRequired);
        }
        expect((await open(_realPin)).status, TransferStatus.pending);
      },
    );

    test('absent with no PIN enforced is accepted', () async {
      start(policy: const PinPolicy.off());
      expect((await open(null)).status, TransferStatus.pending);
    });

    test('well-formed pin with no PIN enforced is accepted', () async {
      start(policy: const PinPolicy.off());
      expect((await open('123456')).status, TransferStatus.pending);
    });

    test('a malformed pin with no PIN enforced is still BAD_REQUEST', () async {
      start(policy: const PinPolicy.off());
      await expectLs(open('12345'), LsErrorCode.badRequest);
      await expectLs(open(''), LsErrorCode.badRequest);
    });
  });
}

// ============================================================ plaintext profile

void _plaintextCharacterisation() {
  // LSP-1 0.1: in the plaintext profile `pin` is accepted and ignored. These tests describe
  // today's behaviour so that the secure-profile fix does not leak into it.
  group('plaintext profile (characterisation)', () {
    test(
      'ApiServer: a malformed string pin is ignored, the session is created',
      () async {
        final rig = await P3Rig.start(secure: false);
        addTearDown(rig.stop);
        for (final v in ['', '12345', 'abcdef', '4829135', 'x' * 10240]) {
          final r = await rig.request(
            'POST',
            '/sessions',
            body: _apiBody(p3Alice, pin: v),
            headers: {'content-type': 'application/json'},
          );
          expect(
            r.status,
            anyOf(200, 202),
            reason: 'pin of ${v.length} chars: ${r.text}',
          );
        }
      },
    );

    test(
      'ApiServer: a non-string pin is a structure error (400), as before',
      () async {
        final rig = await P3Rig.start(secure: false);
        addTearDown(rig.stop);
        final r = await rig.request(
          'POST',
          '/sessions',
          body: _apiBody(p3Alice, pin: 482913),
          headers: {'content-type': 'application/json'},
        );
        expect(r.status, 400);
        expect(r.error['code'], 'BAD_REQUEST');
      },
    );

    test('FileReceiver.createSession: a malformed pin is ignored', () async {
      final rig = P4Rig(secure: false);
      addTearDown(rig.dispose);
      final alice = p4Identity('pin-shape-plain');
      for (final v in ['', '12345', 'abcdef', 'x' * 10240]) {
        final s = await rig.receiver.createSession(
          p4Request(alice, pin: v),
          remoteAddress: '192.0.2.10',
        );
        expect(
          s.status,
          TransferStatus.pending,
          reason: 'pin of ${v.length} chars',
        );
      }
    });
  });
}

void main() {
  group('pin shape: ApiServer layer', _apiTests);
  group('pin shape: FileReceiver layer', _receiverTests);
  _plaintextCharacterisation();
}
