import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/src/clock.dart';
import 'package:libreshare_core/src/model/session_models.dart';
import 'package:libreshare_core/src/transfer/resume_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class FakeClock implements Clock {
  FakeClock(this.t);
  DateTime t;
  @override
  DateTime now() => t;
  void advance(Duration d) => t = t.add(d);
}

const int kChunk = 64 * 1024;
final String kSha = 'ab' * 32;

void main() {
  late Directory tmp;
  late FakeClock clock;
  late File partial;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ls_resume_');
    clock = FakeClock(DateTime.utc(2026, 11, 1, 12));
    partial = File(p.join(tmp.path, 'sub', 'movie.mkv.lspart'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ResumeStore> open({
    int size = 10 * kChunk,
    int chunkSize = kChunk,
    int? chunkCount,
    String? sha256,
    DateTime? modified,
    int persistEvery = 8,
    Future<void> Function()? beforePersist,
  }) => ResumeStore.open(
    partialFile: partial,
    size: size,
    chunkSize: chunkSize,
    chunkCount: chunkCount ?? ((size + chunkSize - 1) ~/ chunkSize),
    sha256: sha256 ?? kSha,
    modified: modified ?? DateTime.utc(2026, 10, 30, 10),
    clock: clock,
    persistEvery: persistEvery,
    beforePersist: beforePersist,
  );

  Map<String, Object?> readSidecar() =>
      jsonDecode(ResumeStore.sidecarFor(partial).readAsStringSync())
          as Map<String, Object?>;

  void makePartial(int length) {
    partial.parent.createSync(recursive: true);
    final raf = partial.openSync(mode: FileMode.write);
    raf.truncateSync(length);
    raf.closeSync();
  }

  test('fresh store: nothing received, sidecar written immediately', () async {
    final s = await open();
    expect(s.resumed, isFalse);
    expect(s.receivedCount, 0);
    expect(s.ranges, isEmpty);
    expect(s.isComplete, isFalse);
    expect(ResumeStore.sidecarFor(partial).path, '${partial.path}.json');
    final j = readSidecar();
    expect(j['size'], 10 * kChunk);
    expect(j['chunkSize'], kChunk);
    expect(j['chunkCount'], 10);
    expect(j['sha256'], kSha);
    expect(j['received'], isEmpty);
  });

  test('persists every 8 chunks (and only then)', () async {
    final s = await open();
    for (var i = 0; i < 7; i++) {
      await s.markReceived(i);
    }
    expect(readSidecar()['received'], isEmpty);
    await s.markReceived(7);
    expect(readSidecar()['received'], [
      [0, 7],
    ]);
    await s.markReceived(8);
    expect(readSidecar()['received'], [
      [0, 7],
    ]);
    // completing persists immediately
    await s.markReceived(9);
    expect(s.isComplete, isTrue);
    expect(readSidecar()['received'], [
      [0, 9],
    ]);
  });

  test('flush() persists on demand', () async {
    final s = await open();
    await s.markReceived(3);
    await s.markReceived(5);
    await s.flush();
    expect(readSidecar()['received'], [
      [3, 3],
      [5, 5],
    ]);
    expect(s.ranges, [
      [3, 3],
      [5, 5],
    ]);
  });

  test('duplicate markReceived is idempotent; out of range throws', () async {
    final s = await open();
    await s.markReceived(2);
    await s.markReceived(2);
    expect(s.receivedCount, 1);
    expect(s.has(2), isTrue);
    expect(s.has(3), isFalse);
    expect(() => s.markReceived(10), throwsRangeError);
    expect(() => s.markReceived(-1), throwsRangeError);
  });

  test(
    'reload after crash: flushed chunks survive, later ones are lost',
    () async {
      final s = await open();
      for (var i = 0; i < 10; i++) {
        // 0..7 persisted at the 8th mark; 8 is in memory only
        if (i == 9) break;
        await s.markReceived(i);
      }
      makePartial(9 * kChunk); // data of chunks 0..8 reached the disk
      final r = await open(); // "restart"
      expect(r.resumed, isTrue);
      expect(expandRanges(r.ranges), {0, 1, 2, 3, 4, 5, 6, 7});
      expect(r.isComplete, isFalse);
    },
  );

  test('reloaded store keeps working and re-persists', () async {
    final s = await open();
    for (var i = 0; i < 8; i++) {
      await s.markReceived(i);
    }
    makePartial(8 * kChunk);
    final r = await open();
    await r.markReceived(8);
    await r.markReceived(9);
    expect(r.isComplete, isTrue);
    expect(readSidecar()['received'], [
      [0, 9],
    ]);
  });

  group('validation on load discards stale state', () {
    Future<void> seed() async {
      final s = await open();
      for (var i = 0; i < 8; i++) {
        await s.markReceived(i);
      }
      makePartial(8 * kChunk);
    }

    Future<void> expectDiscarded(ResumeStore r) async {
      expect(r.resumed, isFalse);
      expect(r.receivedCount, 0);
      expect(partial.existsSync(), isFalse, reason: 'stale partial removed');
      expect(readSidecar()['received'], isEmpty);
    }

    test('matching metadata resumes', () async {
      await seed();
      final r = await open();
      expect(r.resumed, isTrue);
      expect(r.receivedCount, 8);
      expect(partial.existsSync(), isTrue);
    });

    test('different size', () async {
      await seed();
      await expectDiscarded(await open(size: 12 * kChunk));
    });

    test('different chunkSize', () async {
      await seed();
      await expectDiscarded(
        await open(size: 10 * kChunk, chunkSize: 2 * kChunk),
      );
    });

    test('different chunkCount', () async {
      await seed();
      await expectDiscarded(await open(chunkCount: 11));
    });

    test('different sha256', () async {
      await seed();
      await expectDiscarded(await open(sha256: 'cd' * 32));
    });

    test('different modified', () async {
      await seed();
      await expectDiscarded(await open(modified: DateTime.utc(2026, 10, 31)));
    });

    test('partial file missing', () async {
      await seed();
      partial.deleteSync();
      final r = await open();
      expect(r.resumed, isFalse);
      expect(r.receivedCount, 0);
    });

    test('partial file shorter than the recorded chunks', () async {
      await seed();
      makePartial(5 * kChunk);
      await expectDiscarded(await open());
    });

    test('partial file longer than the declared size', () async {
      await seed();
      makePartial(11 * kChunk);
      await expectDiscarded(await open());
    });

    test('corrupt / garbage sidecar', () async {
      await seed();
      ResumeStore.sidecarFor(partial).writeAsStringSync('{not json');
      await expectDiscarded(await open());
    });

    test('sidecar with out-of-range chunk indices', () async {
      await seed();
      final j = readSidecar()
        ..['received'] = [
          [0, 99],
        ];
      ResumeStore.sidecarFor(partial).writeAsStringSync(jsonEncode(j));
      await expectDiscarded(await open());
    });

    test('sidecar with unknown version', () async {
      await seed();
      final j = readSidecar()..['version'] = 99;
      ResumeStore.sidecarFor(partial).writeAsStringSync(jsonEncode(j));
      await expectDiscarded(await open());
    });
  });

  group('24 h resume window (injected Clock)', () {
    Future<void> seed() async {
      final s = await open();
      for (var i = 0; i < 8; i++) {
        await s.markReceived(i);
      }
      makePartial(8 * kChunk);
    }

    test('still valid at 23h59m', () async {
      await seed();
      clock.advance(const Duration(hours: 23, minutes: 59));
      final r = await open();
      expect(r.resumed, isTrue);
    });

    test('discarded after 24h', () async {
      await seed();
      clock.advance(const Duration(hours: 24, seconds: 1));
      final r = await open();
      expect(r.resumed, isFalse);
      expect(r.receivedCount, 0);
      expect(partial.existsSync(), isFalse);
    });

    test('persisting refreshes the window', () async {
      await seed();
      clock.advance(const Duration(hours: 20));
      final r = await open();
      expect(r.resumed, isTrue);
      await r.markReceived(8);
      makePartial(9 * kChunk);
      await r.flush();
      clock.advance(const Duration(hours: 20)); // 40h after creation
      final again = await open();
      expect(again.resumed, isTrue);
    });
  });

  test('beforePersist runs before the sidecar is written', () async {
    // received-range count visible in the sidecar each time the hook runs
    final seen = <int>[];
    final s = await open(
      beforePersist: () async {
        final side = ResumeStore.sidecarFor(partial);
        seen.add(
          side.existsSync() ? (readSidecar()['received']! as List).length : -1,
        );
      },
    );
    await s.markReceived(0);
    await s.flush();
    expect(seen.length, greaterThanOrEqualTo(2));
    // the hook saw the state from BEFORE the chunk was claimed
    expect(seen.last, 0);
    expect(readSidecar()['received'], [
      [0, 0],
    ]);
  });

  test('concurrent markReceived calls are all recorded', () async {
    final s = await open(size: 100 * kChunk);
    await Future.wait([for (var i = 0; i < 100; i++) s.markReceived(i)]);
    await s.flush();
    expect(s.isComplete, isTrue);
    expect(readSidecar()['received'], [
      [0, 99],
    ]);
  });

  test('0-byte file: complete from the start', () async {
    final s = await open(size: 0, chunkCount: 0);
    expect(s.isComplete, isTrue);
    expect(s.ranges, isEmpty);
  });

  test('null sha256 / modified are matched as null', () async {
    final a = await ResumeStore.open(
      partialFile: partial,
      size: 3 * kChunk,
      chunkSize: kChunk,
      chunkCount: 3,
      clock: clock,
    );
    await a.markReceived(0);
    await a.flush();
    makePartial(kChunk);
    final b = await ResumeStore.open(
      partialFile: partial,
      size: 3 * kChunk,
      chunkSize: kChunk,
      chunkCount: 3,
      clock: clock,
    );
    expect(b.resumed, isTrue);
    final c = await ResumeStore.open(
      partialFile: partial,
      size: 3 * kChunk,
      chunkSize: kChunk,
      chunkCount: 3,
      sha256: kSha,
      clock: clock,
    );
    expect(c.resumed, isFalse);
  });

  test('discard() removes sidecar and (by default) the partial', () async {
    final s = await open();
    await s.markReceived(0);
    makePartial(kChunk);
    await s.discard();
    expect(partial.existsSync(), isFalse);
    expect(ResumeStore.sidecarFor(partial).existsSync(), isFalse);
  });

  test('discard(deletePartial: false) keeps the partial file', () async {
    final s = await open();
    makePartial(kChunk);
    await s.discard(deletePartial: false);
    expect(partial.existsSync(), isTrue);
    expect(ResumeStore.sidecarFor(partial).existsSync(), isFalse);
  });

  test('sweepExpired removes only expired pairs', () async {
    final old = File(p.join(tmp.path, 'old.bin.lspart'));
    final fresh = File(p.join(tmp.path, 'deep', 'fresh.bin.lspart'));
    final foreign = File(p.join(tmp.path, 'user.lspart')); // no sidecar
    foreign.writeAsStringSync('mine');
    for (final f in [old, fresh]) {
      final s = await ResumeStore.open(
        partialFile: f,
        size: kChunk,
        chunkSize: kChunk,
        chunkCount: 1,
        clock: clock,
      );
      await s.markReceived(0);
      f.writeAsBytesSync(List.filled(kChunk, 1));
      if (f == old) clock.advance(const Duration(hours: 30));
    }
    // 'fresh' was persisted 30h after 'old'... re-persist fresh now
    final f2 = await ResumeStore.open(
      partialFile: fresh,
      size: kChunk,
      chunkSize: kChunk,
      chunkCount: 1,
      clock: clock,
    );
    await f2.flush();
    final removed = await ResumeStore.sweepExpired(tmp, clock: clock);
    expect(removed, 1);
    expect(old.existsSync(), isFalse);
    expect(ResumeStore.sidecarFor(old).existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(foreign.existsSync(), isTrue);
  });
}
