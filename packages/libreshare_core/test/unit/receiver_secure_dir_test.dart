// Extra items from the Android emulator run (docs/test-reports/android-emulator.md defects 6
// and 7), tested only as far as LSP-1 and the existing receiver parameters define behaviour.
//
// Defect 6 (unwritable download folder surfaced late as PROTOCOL_ERROR): LSP-1 has no rule
// for it. The orchestrator's request is "reject with a clear LsException at createSession time,
// before the user is asked". SPEC-GAP: the error code. LSP-1 4.3.5 offers `INSUFFICIENT_STORAGE`
// (507, not retryable, the client maps it to DISK_FULL) and `INTERNAL` (500, retryable, so a
// client would retry three times for nothing); 507 is the safer reading and is asserted.
//
// Defect 7 (an accepted session that receives nothing never expires): LSP-1 4.4 puts the chunk
// idle timeout (30 s LAN / 60 s tunnel) in Increment 4 [I4]; Increment 3 specifies nothing
// except the existing `sessionTtl` parameter ("Idle sessions (and their in-memory state) are
// dropped after this long"). That is what is tested. SPEC-GAP (not tested): expiry that fires
// without anybody polling, an idle period shorter than 24 h by default, and what happens to
// the partial files; see docs/plans/inc3-p4-tests.md for the proposal.
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p4_support.dart';

bool _isRoot() {
  if (Platform.isWindows) return false;
  try {
    return Process.runSync('id', ['-u']).stdout.toString().trim() == '0';
  } on Object {
    return false;
  }
}

void main() {
  final tx = p4Identity(kTxId);
  late P4Rig rig;
  final extraDirs = <Directory>[];

  tearDown(() {
    rig.dispose();
    for (final d in extraDirs) {
      try {
        // restore permissions so the delete works
        if (d.existsSync() && !Platform.isWindows) {
          Process.runSync('chmod', ['-R', 'u+rwx', d.path]);
        }
        d.deleteSync(recursive: true);
      } on FileSystemException {
        // best effort
      }
    }
    extraDirs.clear();
  });

  /// A download directory that cannot be created: its parent is a regular file.
  Directory blockedDir() {
    final base = Directory.systemTemp.createTempSync('ls_p4_dir_');
    extraDirs.add(base);
    File('${base.path}/blocker').writeAsStringSync('not a directory');
    return Directory('${base.path}/blocker/Downloads');
  }

  /// A directory that exists but is read-only for this user.
  Directory readOnlyDir() {
    final base = Directory.systemTemp.createTempSync('ls_p4_ro_');
    extraDirs.add(base);
    final d = Directory('${base.path}/Downloads')..createSync();
    final r = Process.runSync('chmod', ['0555', d.path]);
    expect(r.exitCode, 0);
    return d;
  }

  void nothingAskedOfTheUser() {
    expect(rig.receiver.pendingSessionIds, isEmpty);
    expect(rig.receiver.activeSessionCount, 0);
    expect(rig.eventsOf<SessionCreated>(), isEmpty);
  }

  group('unwritable or missing download directory is refused up front (defect 6)', () {
    test('secure: directory that cannot be created -> LsException 507, no prompt, no session', () async {
      rig = P4Rig(downloadDir: blockedDir());
      final e = await expectLs(rig.open(tx), LsErrorCode.insufficientStorage);
      expect(e.message, isNotEmpty);
      expect(e.retryable, isFalse);
      nothingAskedOfTheUser();
    });

    test(
      'secure: existing but read-only directory -> LsException 507',
      () async {
        rig = P4Rig(downloadDir: readOnlyDir());
        await expectLs(rig.open(tx), LsErrorCode.insufficientStorage);
        nothingAskedOfTheUser();
      },
      skip: (Platform.isWindows || _isRoot())
          ? 'permissions are not enforced here (Windows or root)'
          : false,
    );

    test('positive twin: a normal writable directory gives a prompt', () async {
      rig = P4Rig();
      final st = await rig.open(tx);
      expect(st.status, TransferStatus.pending);
      expect(rig.eventsOf<SessionCreated>(), hasLength(1));
    });

    test(
      'the refusal does not depend on auto-accept: it happens before any start',
      () async {
        rig = P4Rig(downloadDir: blockedDir(), autoAccept: true);
        await expectLs(rig.open(tx), LsErrorCode.insufficientStorage);
        nothingAskedOfTheUser();
      },
    );

    test('the refusal is an LsException, never a failed session reached later', () async {
      rig = P4Rig(downloadDir: blockedDir());
      Object? caught;
      try {
        await rig.open(tx);
      } on Object catch (e) {
        caught = e;
      }
      expect(caught, isA<LsException>());
      expect(
        rig.eventsOf<SessionFinished>(),
        isEmpty,
        reason:
            'no session was ever created, so none can fail with PROTOCOL_ERROR',
      );
    });

    test(
      'a failed proof is still reported as 401, not as a storage problem',
      () async {
        rig = P4Rig(downloadDir: blockedDir());
        await expectLs(
          rig.receiver.createAuthenticatedSession(
            p4Request(tx),
            remoteAddress: '192.0.2.10',
            peer: null,
          ),
          LsErrorCode.authInvalid,
        );
      },
    );

    test('plaintext profile: the same refusal at createSession (the prototype app hit it)', () async {
      rig = P4Rig(secure: false, downloadDir: blockedDir());
      await expectLs(
        rig.receiver.createSession(p4Request(tx), remoteAddress: '192.0.2.10'),
        LsErrorCode.insufficientStorage,
      );
      nothingAskedOfTheUser();
    });

    test(
      'plaintext profile: a writable directory is unchanged (positive twin)',
      () async {
        rig = P4Rig(secure: false);
        final st = await rig.receiver.createSession(
          p4Request(tx),
          remoteAddress: '192.0.2.10',
        );
        expect(st.status, TransferStatus.pending);
      },
    );
  });

  // Existing receiver contract: `sessionTtl` drops idle sessions (checked lazily on the next
  // call, driven by the injected Clock). The secure entry point must honour it too.
  group(
    'idle sessions expire after sessionTtl (defect 7, as far as specified)',
    () {
      const ttl = Duration(minutes: 10);

      Future<(SessionStatus, String)> acceptedSession() async {
        final st = await rig.open(tx);
        final ok = await rig.receiver.accept(st.sessionId);
        return (ok, ok.acceptedFiles['f0']!.token);
      }

      test('an accepted session with no activity for ttl + 1 s is gone and reported as TIMEOUT', () async {
        rig = P4Rig(sessionTtl: ttl);
        final (st, _) = await acceptedSession();
        rig.clock.jumpWallClock(ttl + const Duration(seconds: 1));
        await expectLs(
          rig.receiver.getSession(st.sessionId),
          LsErrorCode.notFound,
        );
        final fin = rig.eventsOf<SessionFinished>().single;
        expect(fin.success, isFalse);
        expect(fin.reason, 'TIMEOUT');
        expect(rig.receiver.activeSessionCount, 0);
      });

      test('positive twin: just inside the ttl the session is alive', () async {
        rig = P4Rig(sessionTtl: ttl);
        final (st, _) = await acceptedSession();
        rig.clock.jumpWallClock(ttl - const Duration(seconds: 1));
        expect(
          (await rig.receiver.getSession(st.sessionId)).status,
          TransferStatus.inProgress,
        );
        expect(rig.eventsOf<SessionFinished>(), isEmpty);
      });

      test(
        'every call on the session counts as activity: the ttl restarts',
        () async {
          rig = P4Rig(sessionTtl: ttl);
          final (st, token) = await acceptedSession();
          for (var i = 0; i < 3; i++) {
            rig.clock.jumpWallClock(const Duration(minutes: 6));
            // 18 minutes in total, never 10 idle minutes in a row
            await rig.receiver.fileState(st.sessionId, 'f0', token: token);
          }
          expect(
            (await rig.receiver.getSession(st.sessionId)).status,
            TransferStatus.inProgress,
          );
        },
      );

      test('the expired session no longer reserves its file name', () async {
        rig = P4Rig(sessionTtl: ttl);
        await acceptedSession(); // accepted, then nothing arrives
        rig.clock.jumpWallClock(ttl + const Duration(minutes: 1));
        // a new session for the same name (a retry by the sender) finishes under the plain
        // name, not as "a (1).bin"
        final again = await rig.open(tx);
        final ok = await rig.receiver.accept(again.sessionId);
        final t2 = ok.acceptedFiles['f0']!.token;
        await rig.receiver.putChunk(
          again.sessionId,
          'f0',
          0,
          Stream.value(p4Bytes(0)),
          token: t2,
        );
        await rig.receiver.completeFile(again.sessionId, 'f0', token: t2);
        final saved = rig.eventsOf<FileSaved>().single;
        expect(
          saved.path.endsWith('${Platform.pathSeparator}a.bin'),
          isTrue,
          reason: 'saved as ${saved.path.split(Platform.pathSeparator).last}',
        );
      });

      test('creating a new SECURE session evicts stale ones (SessionFinished TIMEOUT)', () async {
        rig = P4Rig(sessionTtl: ttl);
        final (stale, _) = await acceptedSession();
        rig.clock.jumpWallClock(ttl + const Duration(seconds: 5));
        await rig.open(tx, remote: '198.51.100.9'); // any new secure request
        final fin = rig.eventsOf<SessionFinished>().single;
        expect(fin.reason, 'TIMEOUT');
        expect(fin.sessionId, stale.sessionId);
      });

      test(
        'an expired pending prompt does not count against the pending caps',
        () async {
          rig = P4Rig(
            sessionTtl: ttl,
            consent: const ConsentPolicy(maxPendingPerIp: 1),
          );
          await rig.open(tx);
          await expectLs(rig.open(tx), LsErrorCode.rateLimited);
          rig.clock.jumpWallClock(ttl + const Duration(seconds: 1));
          expect((await rig.open(tx)).status, TransferStatus.pending);
        },
      );
    },
  );
}
