// Speed wave S2 (tester): native SHA-256 behind the Sha256Provider seam.
// Contract: docs/plans/inc4-speed-seams.md behaviours 1, 2, 3, 4, 7, 9.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:libreshare_core/src/transfer/hashing.dart';
import 'package:libreshare_core/src/transfer/native_sha256.dart';
import 'package:test/test.dart';

const int mib = 1024 * 1024;
const _emptyHex =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const _abcHex =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const _millionAHex =
    'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0';

String ref(List<int> b) => crypto.sha256.convert(b).toString();

Uint8List seeded(int n, int seed) {
  final r = Random(seed);
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

/// True when this host demonstrably has a loadable system SHA-256 library
/// (decided WITHOUT the code under test): then a native provider MUST load.
bool hostHasNativeLibrary() {
  if (Platform.isWindows) return true; // bcrypt.dll ships with every Windows
  if (!Platform.isLinux) return false; // macOS/others: not asserted here
  for (final n in ['libcrypto.so.3', 'libcrypto.so.1.1', 'libcrypto.so']) {
    try {
      DynamicLibrary.open(n);
      return true;
    } on Object {
      // try the next one
    }
  }
  return false;
}

String _hexOfPieces(Sha256Incremental inc, Uint8List data, Random r) {
  var i = 0;
  while (i < data.length) {
    final n = min(r.nextInt(64 * 1024) + 1, data.length - i);
    inc.add(Uint8List.sublistView(data, i, i + n));
    i += n;
  }
  final h = inc.finishHex();
  inc.dispose();
  return h;
}

void main() {
  final original = activeSha256Provider;
  tearDown(() => activeSha256Provider = original);

  final expectNative = hostHasNativeLibrary();
  final native = tryLoadNativeSha256();

  final providers = <String, IncrementalSha256Provider>{
    'pure-dart': const PureDartSha256Provider(),
    'native': ?native,
  };

  group('host sanity', () {
    test('PureDartSha256Provider is an IncrementalSha256Provider', () {
      expect(const PureDartSha256Provider(), isA<IncrementalSha256Provider>());
    });

    test('a native provider loads on a host that has a system SHA-256 '
        'library (Linux with libcrypto, Windows)', () {
      if (expectNative) {
        expect(
          native,
          isNotNull,
          reason:
              'this host can open a system SHA-256 library '
              '(libcrypto/bcrypt) but tryLoadNativeSha256() returned null',
        );
        expect(native, isA<NativeSha256Provider>());
        expect(native!.libraryName, isNotEmpty);
        final cands = nativeSha256Candidates(
          os: Platform.operatingSystem,
          env: Platform.environment,
        );
        expect(cands, contains(native.libraryName));
      } else {
        expect(native, anyOf(isNull, isA<NativeSha256Provider>()));
      }
    });
  });

  for (final e in providers.entries) {
    final name = e.key;
    final p = e.value;
    group('behaviour 1 [$name]: digests equal package:crypto', () {
      test('NIST vectors: "", "abc", 1,000,000 x "a"', () {
        expect(p.hashBytes(const <int>[]), _emptyHex);
        expect(p.hashBytes(utf8.encode('abc')), _abcHex);
        final million = Uint8List(1000000)..fillRange(0, 1000000, 0x61);
        expect(p.hashBytes(million), _millionAHex);
        var inc = p.startIncremental();
        expect(inc.finishHex(), _emptyHex);
        inc.dispose();
        inc = p.startIncremental()..add(utf8.encode('abc'));
        expect(inc.finishHex(), _abcHex);
        inc.dispose();
        inc = p.startIncremental();
        for (var i = 0; i < million.length; i += 997) {
          inc.add(Uint8List.sublistView(million, i, min(i + 997, 1000000)));
        }
        expect(inc.finishHex(), _millionAHex);
        inc.dispose();
      });

      for (final len in [
        0, 1, 55, 56, 63, 64, 65, //
        4 * mib - 1, 4 * mib, 4 * mib + 1,
      ]) {
        test('length $len: one-shot, single add, random splits', () {
          final data = seeded(len, len + 17);
          final want = ref(data);
          expect(p.hashBytes(data), want, reason: 'hashBytes');
          var inc = p.startIncremental()..add(data);
          expect(inc.finishHex(), want, reason: 'single add');
          inc.dispose();
          inc = p.startIncremental();
          expect(_hexOfPieces(inc, data, Random(len)), want, reason: 'splits');
          if (len <= 130) {
            inc = p.startIncremental();
            for (final b in data) {
              inc.add([b]);
            }
            expect(inc.finishHex(), want, reason: 'one byte at a time');
            inc.dispose();
          }
        });
      }

      test('seeded random data, random incremental piece sizes 1..64 KiB', () {
        for (var seed = 1; seed <= 5; seed++) {
          final data = seeded(1 * mib + seed * 977, seed);
          final got = _hexOfPieces(
            p.startIncremental(),
            data,
            Random(seed * 31),
          );
          expect(got, ref(data), reason: 'seed $seed');
        }
      });

      test('Uint8List views with offsetInBytes != 0', () {
        final big = seeded(300000, 99);
        for (final off in [1, 3, 7, 64, 4097, 65535]) {
          final view = Uint8List.sublistView(big, off, off + 100000 + off);
          expect(view.offsetInBytes, off);
          final want = ref(view.toList());
          expect(p.hashBytes(view), want, reason: 'hashBytes off=$off');
          final inc = p.startIncremental()..add(view);
          expect(inc.finishHex(), want, reason: 'add off=$off');
          inc.dispose();
        }
        // a view built with Uint8List.view over a shared ByteBuffer
        final view = Uint8List.view(big.buffer, 12345, 54321);
        final inc = p.startIncremental()
          ..add(Uint8List.sublistView(view, 11, 5000))
          ..add(Uint8List.sublistView(view, 5000));
        expect(inc.finishHex(), ref(Uint8List.sublistView(view, 11).toList()));
        inc.dispose();
      });

      test('plain List<int> (growable, fixed-length, const)', () {
        final growable = <int>[1, 2, 3, 250, 251, 252, 0, 255];
        expect(p.hashBytes(growable), ref(Uint8List.fromList(growable)));
        final fixed = List<int>.generate(
          1000,
          (i) => (i * 7) & 0xff,
          growable: false,
        );
        expect(p.hashBytes(fixed), ref(fixed));
        const c = <int>[97, 98, 99];
        expect(p.hashBytes(c), _abcHex);
        final inc = p.startIncremental()
          ..add(growable)
          ..add(fixed)
          ..add(const <int>[])
          ..add(c);
        expect(inc.finishHex(), ref([...growable, ...fixed, ...c]));
        inc.dispose();
      });

      test('the same provider hashes different inputs one after the other '
          '(no stale buffer)', () {
        final a = seeded(70000, 1);
        final b = seeded(70001, 2);
        final c = seeded(5, 3);
        for (var round = 0; round < 3; round++) {
          expect(p.hashBytes(a), ref(a));
          var inc = p.startIncremental()..add(b);
          expect(inc.finishHex(), ref(b));
          inc.dispose();
          expect(p.hashBytes(c), ref(c));
          inc = p.startIncremental()..add(a);
          expect(inc.finishHex(), ref(a));
          inc.dispose();
          expect(p.hashBytes(const <int>[]), _emptyHex);
        }
      });

      test('hashStream: pieces, empty stream, error propagates', () async {
        final data = seeded(1 * mib + 3, 12);
        Stream<List<int>> pieces() async* {
          for (var i = 0; i < data.length; i += 99991) {
            yield Uint8List.sublistView(data, i, min(i + 99991, data.length));
          }
        }

        expect(await p.hashStream(pieces()), ref(data));
        expect(await p.hashStream(const Stream<List<int>>.empty()), _emptyHex);
        Stream<List<int>> failing() async* {
          yield [1, 2, 3];
          throw StateError('boom');
        }

        await expectLater(p.hashStream(failing()), throwsStateError);
        // still usable afterwards
        expect(p.hashBytes(utf8.encode('abc')), _abcHex);
      });
    });

    group('behaviour 7 [$name]: misuse and resources', () {
      test('add / finishHex after finishHex throw StateError', () {
        final inc = p.startIncremental()..add([1, 2, 3]);
        expect(inc.finishHex(), ref([1, 2, 3]));
        expect(() => inc.add([4]), throwsStateError);
        expect(inc.finishHex, throwsStateError);
        inc.dispose();
      });

      test('dispose twice, and dispose after finishHex, are fine', () {
        final a = p.startIncremental()..add([1]);
        a.dispose();
        a.dispose();
        final b = p.startIncremental()..add([1]);
        b.finishHex();
        b.dispose();
        b.dispose();
        // provider still healthy
        expect(p.hashBytes(utf8.encode('abc')), _abcHex);
      });

      test(
        '1,000 interleaved incrementals give independent, correct digests',
        () {
          final r = Random(1000);
          const n = 1000;
          final datas = [
            for (var i = 0; i < n; i++) seeded(r.nextInt(100000) + 1, i),
          ];
          final incs = [for (var i = 0; i < n; i++) p.startIncremental()];
          final offsets = List<int>.filled(n, 0);
          var left = n;
          final live = List<bool>.filled(n, true);
          while (left > 0) {
            final i = r.nextInt(n);
            if (!live[i]) continue;
            final d = datas[i];
            final take = min(r.nextInt(30000) + 1, d.length - offsets[i]);
            incs[i].add(
              Uint8List.sublistView(d, offsets[i], offsets[i] + take),
            );
            offsets[i] += take;
            if (offsets[i] == d.length) {
              live[i] = false;
              left--;
            }
          }
          for (var i = 0; i < n; i++) {
            expect(
              incs[i].finishHex(),
              ref(datas[i]),
              reason: 'incremental $i',
            );
            incs[i].dispose();
          }
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test('10,000 start/dispose cycles do not grow RSS by more than 20 MB '
          '(measured in an idle child process)', () async {
        final growth = await _rssGrowthInChild(name == 'native');
        expect(
          growth,
          lessThan(20 * mib),
          reason: 'RSS grew by ${growth ~/ 1024} KiB over 10,000 cycles',
        );
      }, timeout: const Timeout(Duration(seconds: 120)));
    });
  }

  group('newSha256Incremental (the seam)', () {
    test('uses the active provider when it is incremental', () {
      final fake = _CountingIncremental();
      activeSha256Provider = fake;
      final inc = newSha256Incremental()..add(utf8.encode('abc'));
      expect(inc.finishHex(), _abcHex);
      inc.dispose();
      expect(fake.started, 1);
    });

    test('wraps pure Dart when the active provider is not incremental', () {
      activeSha256Provider = _PlainProvider();
      final data = seeded(100000, 3);
      final inc = newSha256Incremental()..add(data);
      expect(inc.finishHex(), ref(data));
      inc.dispose();
    });

    test('works with the default and with the best provider', () {
      activeSha256Provider = const PureDartSha256Provider();
      var inc = newSha256Incremental()..add(utf8.encode('abc'));
      expect(inc.finishHex(), _abcHex);
      inc.dispose();
      installBestSha256Provider();
      inc = newSha256Incremental()..add(utf8.encode('abc'));
      expect(inc.finishHex(), _abcHex);
      inc.dispose();
    });
  });

  group('behaviour 2: load-time known-answer test (KAT)', () {
    test('control: an identity tamper hook keeps the provider and is called '
        'for the NIST vectors', () {
      var calls = 0;
      final p = tryLoadNativeSha256(
        tamperDigestForTest: (h) {
          calls++;
          return h;
        },
      );
      if (expectNative) {
        expect(p, isNotNull);
        expect(
          calls,
          greaterThanOrEqualTo(3),
          reason:
              'the KAT must pass at least the 3 NIST digests through the hook',
        );
      }
    });

    final tampers = <String, String Function(String)>{
      'every digest has its first nibble changed': (h) =>
          '${h[0] == '0' ? '1' : '0'}${h.substring(1)}',
      'every digest has its last nibble changed': (h) =>
          '${h.substring(0, 63)}${h[63] == 'f' ? 'e' : 'f'}',
      'only the digest of "" is changed': (h) => h == _emptyHex ? 'f' * 64 : h,
      'only the digest of "abc" is changed': (h) => h == _abcHex ? 'f' * 64 : h,
      'only the digest of 1,000,000 x "a" is changed': (h) =>
          h == _millionAHex ? 'f' * 64 : h,
      'every digest is the empty string': (h) => '',
      'every digest is all zeros': (h) => '0' * 64,
    };
    for (final t in tampers.entries) {
      test('KAT rejects: ${t.key} -> null', () {
        expect(tryLoadNativeSha256(tamperDigestForTest: t.value), isNull);
      });
    }

    test('a throwing hook -> null, never throws', () {
      expect(
        tryLoadNativeSha256(
          tamperDigestForTest: (h) => throw StateError('hook exploded'),
        ),
        isNull,
      );
    });

    test('missing / unusable library candidates -> null, never throws', () {
      final tmp = Directory.systemTemp.createTempSync('ls_s2_nat_');
      try {
        final garbage = File('${tmp.path}/libcrypto.so.3')
          ..writeAsBytesSync(seeded(4096, 1));
        final dir = Directory('${tmp.path}/libcrypto.so')..createSync();
        for (final cands in <List<String>>[
          const [],
          const ['definitely_not_a_library.so'],
          const ['/nonexistent/dir/libcrypto.so.3'],
          const [''],
          [garbage.path],
          [dir.path],
          // loads fine but has no EVP / bcrypt symbols
          if (Platform.isLinux) const ['libc.so.6', 'libm.so.6'],
        ]) {
          expect(
            tryLoadNativeSha256(candidates: cands),
            isNull,
            reason: 'candidates $cands',
          );
        }
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('a missing candidate is skipped, a later good one is used', () {
      final host = nativeSha256Candidates(
        os: Platform.operatingSystem,
        env: Platform.environment,
      );
      final p = tryLoadNativeSha256(
        candidates: ['/nonexistent/dir/libcrypto.so.3', ...host],
      );
      if (expectNative) {
        expect(p, isNotNull);
        expect(p!.hashBytes(utf8.encode('abc')), _abcHex);
      } else {
        expect(p, anyOf(isNull, isA<NativeSha256Provider>()));
      }
    });

    test('a loaded provider hashes correctly in a fresh isolate', () async {
      final got = await Isolate.run(_hashAbcInFreshIsolate);
      expect(got, expectNative ? _abcHex : anyOf(_abcHex, 'none'));
    });
  });

  group('behaviour 3: fallback is silent and safe', () {
    test('allowNative:false installs and returns PureDartSha256Provider', () {
      final r = installBestSha256Provider(allowNative: false);
      expect(r, isA<PureDartSha256Provider>());
      expect(identical(activeSha256Provider, r), isTrue);
      final inc = newSha256Incremental()..add(utf8.encode('abc'));
      expect(inc.finishHex(), _abcHex);
      inc.dispose();
    });

    test('the default picks native when it loads, pure Dart otherwise; '
        'idempotent; can switch back and forth', () {
      activeSha256Provider = const PureDartSha256Provider();
      final r1 = installBestSha256Provider();
      expect(identical(activeSha256Provider, r1), isTrue);
      if (Platform.environment['LS_NO_NATIVE_SHA'] == '1') {
        expect(r1, isA<PureDartSha256Provider>());
      } else if (native != null) {
        expect(r1, isA<NativeSha256Provider>());
      } else {
        expect(r1, isA<PureDartSha256Provider>());
      }
      final r2 = installBestSha256Provider();
      expect(r2.runtimeType, r1.runtimeType);
      expect(identical(activeSha256Provider, r2), isTrue);
      expect(sha256OfBytes(utf8.encode('abc')), _abcHex);
      installBestSha256Provider(allowNative: false);
      expect(activeSha256Provider, isA<PureDartSha256Provider>());
      expect(sha256OfBytes(utf8.encode('abc')), _abcHex);
    });

    group(
      'LS_NO_NATIVE_SHA (child process; this process env is untouched)',
      () {
        Future<Map<String, String>> runChild(Map<String, String> env) async {
          final lib = await Isolate.resolvePackageUri(
            Uri.parse('package:libreshare_core/libreshare_core.dart'),
          );
          final script = File.fromUri(
            lib!.resolve('../test/unit/native_sha256_child.dart'),
          );
          expect(script.existsSync(), isTrue, reason: script.path);
          final res = await Process.run(
            Platform.resolvedExecutable,
            [script.path],
            environment: env,
            includeParentEnvironment: false,
          ).timeout(const Duration(seconds: 90));
          expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
          final line = (res.stdout as String)
              .split('\n')
              .firstWhere((l) => l.startsWith('ACTIVE='));
          return {
            for (final kv in line.trim().split(' '))
              kv.split('=')[0]: kv.split('=')[1],
          };
        }

        Map<String, String> baseEnv() => {
          for (final k in [
            'PATH',
            'HOME',
            'PUB_CACHE',
            'TMPDIR',
            'SystemRoot',
            'LD_LIBRARY_PATH',
          ])
            if (Platform.environment[k] != null) k: Platform.environment[k]!,
        };

        test('LS_NO_NATIVE_SHA=1 -> pure Dart, digests still right', () async {
          final r = await runChild({...baseEnv(), 'LS_NO_NATIVE_SHA': '1'});
          expect(r['ACTIVE'], 'pure');
          expect(r['RETURNED_IS_ACTIVE'], 'true');
          expect(r['ABC'], _abcHex);
        }, timeout: const Timeout(Duration(seconds: 120)));

        test(
          'variable not set -> best provider (native where the host has one)',
          () async {
            final r = await runChild(baseEnv());
            expect(
              r['ACTIVE'],
              expectNative ? 'other' : anyOf('pure', 'other'),
            );
            expect(r['RETURNED_IS_ACTIVE'], 'true');
            expect(r['ABC'], _abcHex);
          },
          timeout: const Timeout(Duration(seconds: 120)),
        );
      },
    );
  });

  group('behaviour 4: the library search cannot be hijacked', () {
    test('linux: bare names resolved by the system loader, in this order', () {
      expect(nativeSha256Candidates(os: 'linux'), [
        'libcrypto.so.3',
        'libcrypto.so.1.1',
        'libcrypto.so',
      ]);
      expect(nativeSha256Candidates(os: 'linux', env: {'SystemRoot': 'x'}), [
        'libcrypto.so.3',
        'libcrypto.so.1.1',
        'libcrypto.so',
      ]);
    });

    test('macos: /usr/lib/libcrypto.dylib only', () {
      expect(nativeSha256Candidates(os: 'macos'), ['/usr/lib/libcrypto.dylib']);
    });

    test('android and ios: none (pool path comes in wave S1)', () {
      expect(nativeSha256Candidates(os: 'android'), isEmpty);
      expect(nativeSha256Candidates(os: 'ios'), isEmpty);
    });

    test(r'windows with SystemRoot C:\Windows: only absolute bcrypt paths '
        r'below C:\Windows\System32', () {
      final c = nativeSha256Candidates(
        os: 'windows',
        env: {'SystemRoot': r'C:\Windows'},
      );
      expect(c, isNotEmpty);
      for (final path in c) {
        expect(
          path.toLowerCase(),
          startsWith(r'c:\windows\system32\'),
          reason: path,
        );
        expect(path.toLowerCase(), contains('bcrypt'), reason: path);
        expect(path, isNot(contains('..')));
        expect(RegExp(r'^[A-Za-z]:\\').hasMatch(path), isTrue, reason: path);
      }
    });

    test('windows follows SystemRoot (D:\\WINNT)', () {
      final c = nativeSha256Candidates(
        os: 'windows',
        env: {'SystemRoot': r'D:\WINNT'},
      );
      expect(c, isNotEmpty);
      for (final path in c) {
        expect(path.toLowerCase(), startsWith(r'd:\winnt\system32\'));
      }
    });

    test('windows with no SystemRoot -> empty', () {
      expect(nativeSha256Candidates(os: 'windows', env: {}), isEmpty);
      expect(
        nativeSha256Candidates(os: 'windows', env: {'PATH': r'C:\evil'}),
        isEmpty,
      );
    });

    for (final bad in [
      '',
      'Windows',
      r'.\Windows',
      r'..\evil',
      r'evil\Windows',
      'C:Windows', // drive-relative
      './x',
    ]) {
      test('windows with relative / unusable SystemRoot "$bad" -> empty', () {
        expect(
          nativeSha256Candidates(os: 'windows', env: {'SystemRoot': bad}),
          isEmpty,
        );
      });
    }

    test('windows: no candidate is ever a bare / relative name', () {
      for (final env in <Map<String, String>>[
        {'SystemRoot': r'C:\Windows'},
        {'SystemRoot': r'C:\Windows\'},
        {'SystemRoot': r'Z:\x y\Windows'},
        {'SystemRoot': 'rel', 'PATH': '.'},
      ]) {
        for (final path in nativeSha256Candidates(os: 'windows', env: env)) {
          expect(
            RegExp(r'^[A-Za-z]:\\').hasMatch(path),
            isTrue,
            reason: '$path for $env',
          );
        }
      }
    });
  });

  group('behaviour 9: coarse speed guard', () {
    test('native is at least 5x faster than pure Dart on 64 MiB, or pure '
        'Dart is the active provider', () {
      final best = installBestSha256Provider();
      final buf = seeded(4 * mib, 5);
      const reps = 16; // 64 MiB
      const pure = PureDartSha256Provider();
      final want = pure.hashBytes(buf);

      if (native == null) {
        expect(
          expectNative,
          isFalse,
          reason: 'a native provider should have loaded on this host',
        );
        expect(
          best,
          isA<PureDartSha256Provider>(),
          reason:
              'no native SHA-256 library loads on this host; the best provider '
              'must then be pure Dart (speed guard not applicable)',
        );
        return;
      }
      expect(best, isA<NativeSha256Provider>());
      var sw = Stopwatch()..start();
      for (var i = 0; i < reps; i++) {
        expect(pure.hashBytes(buf), want);
      }
      final pureMicros = sw.elapsedMicroseconds;
      var bestMicros = 1 << 62;
      for (var round = 0; round < 3; round++) {
        sw = Stopwatch()..start();
        for (var i = 0; i < reps; i++) {
          expect(best.hashBytes(buf), want);
        }
        bestMicros = min(bestMicros, sw.elapsedMicroseconds);
      }
      final ratio = pureMicros / max(bestMicros, 1);
      expect(
        ratio,
        greaterThanOrEqualTo(5),
        reason:
            'native ${(64 * 1e6 / bestMicros).toStringAsFixed(0)} MiB/s vs pure '
            '${(64 * 1e6 / pureMicros).toStringAsFixed(0)} MiB/s '
            '(ratio ${ratio.toStringAsFixed(1)}, need >= 5)',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

String _hashAbcInFreshIsolate() {
  final p = tryLoadNativeSha256();
  return p == null ? 'none' : p.hashBytes(utf8.encode('abc'));
}

class _PlainProvider implements Sha256Provider {
  @override
  String hashBytes(List<int> bytes) => ref(bytes);
  @override
  Future<String> hashStream(Stream<List<int>> input) async =>
      ref([for (final l in await input.toList()) ...l]);
}

class _CountingIncremental implements IncrementalSha256Provider {
  int started = 0;
  @override
  String hashBytes(List<int> bytes) => ref(bytes);
  @override
  Future<String> hashStream(Stream<List<int>> input) async =>
      ref([for (final l in await input.toList()) ...l]);
  @override
  Sha256Incremental startIncremental() {
    started++;
    return const PureDartSha256Provider().startIncremental();
  }
}

/// Runs the 10,000-cycle loop in `native_sha256_child.dart rss <mode>` and
/// returns its RSS growth in bytes.
Future<int> _rssGrowthInChild(bool native) async {
  final lib = await Isolate.resolvePackageUri(
    Uri.parse('package:libreshare_core/libreshare_core.dart'),
  );
  final script = File.fromUri(
    lib!.resolve('../test/unit/native_sha256_child.dart'),
  );
  expect(script.existsSync(), isTrue, reason: script.path);
  final env = {
    for (final k in [
      'PATH',
      'HOME',
      'PUB_CACHE',
      'TMPDIR',
      'SystemRoot',
      'LD_LIBRARY_PATH',
    ])
      if (Platform.environment[k] != null) k: Platform.environment[k]!,
  };
  final res = await Process.run(
    Platform.resolvedExecutable,
    [script.path, 'rss', native ? 'native' : 'pure'],
    environment: env,
    includeParentEnvironment: false,
  ).timeout(const Duration(seconds: 100));
  expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
  final line = (res.stdout as String)
      .split('\n')
      .firstWhere((l) => l.startsWith('RSS_GROWTH='));
  final v = line.trim().substring('RSS_GROWTH='.length);
  expect(v, isNot('NONE'), reason: 'native provider did not load in child');
  return int.parse(v);
}
