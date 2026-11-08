import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_core/src/discovery/announce_codec.dart';
import 'package:libreshare_core/src/model/file_item.dart';
import 'package:libreshare_core/src/model/ls_exception.dart';
import 'package:libreshare_core/src/model/session_models.dart';
import 'package:libreshare_core/src/protocol.dart';
import 'package:libreshare_core/src/share/share_link.dart';
import 'package:libreshare_core/src/transfer/chunker.dart';
import 'package:libreshare_core/src/transfer/filename_sanitizer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('1. Chunker math & 64-bit property tests (FR-08)', () {
    const chunker = Chunker();
    const cs = kChunkSize; // 4 MiB = 4194304 bytes

    test('boundary sizes [0, 1, cs-1, cs, cs+1, 2cs-1, 2cs, 2cs+1, 3cs-1, 3cs, 3cs+1]', () {
      final boundarySizes = <int>[
        0,
        1,
        cs - 1,
        cs,
        cs + 1,
        2 * cs - 1,
        2 * cs,
        2 * cs + 1,
        3 * cs - 1,
        3 * cs,
        3 * cs + 1,
      ];

      for (final size in boundarySizes) {
        final expectedCount = size == 0 ? 0 : ((size + cs - 1) ~/ cs);
        expect(
          chunker.chunkCount(size),
          expectedCount,
          reason: 'chunkCount failed for size $size',
        );

        final ranges = chunker.ranges(size).toList();
        expect(
          ranges.length,
          expectedCount,
          reason: 'ranges.length != chunkCount for size $size',
        );

        if (size == 0) {
          expect(ranges, isEmpty);
          continue;
        }

        var offset = 0;
        for (var i = 0; i < ranges.length; i++) {
          final r = ranges[i];
          expect(r.index, i);
          expect(r.start, offset);
          expect(r.end, greaterThan(r.start));
          expect(r.end, lessThanOrEqualTo(size));

          if (i < ranges.length - 1) {
            expect(r.length, cs);
          } else {
            expect(r.length, lessThanOrEqualTo(cs));
            expect(r.end, size);
          }
          offset = r.end;
        }
        expect(offset, size);
      }
    });

    test(
      '64-bit offsets and huge file arithmetic (2^32-1, 2^32, 2^32+1, 2^53-1)',
      () {
        final hugeSizes = <int>[
          4294967295, // 2^32 - 1 (4 GiB - 1 B)
          4294967296, // 2^32 (4 GiB)
          4294967297, // 2^32 + 1 (4 GiB + 1 B)
          10737418240, // 10 GiB
          9007199254740991, // 2^53 - 1 (max safe JS / Dart integer ~ 9 PB)
        ];

        for (final size in hugeSizes) {
          final count = chunker.chunkCount(size);
          expect(count, greaterThan(0));

          // Test first range
          final first = chunker.range(size, 0);
          expect(first.index, 0);
          expect(first.start, 0);
          expect(first.length, cs);
          expect(first.end, cs);

          // Test last range
          final lastIndex = count - 1;
          final last = chunker.range(size, lastIndex);
          expect(last.index, lastIndex);
          expect(last.end, size);
          expect(last.length, greaterThan(0));
          expect(last.length, lessThanOrEqualTo(cs));
        }
      },
    );

    test('random size property test (500 seeded iterations)', () {
      final rng = Random(1337);
      for (var i = 0; i < 500; i++) {
        // Random sizes up to 100 GiB (combining two 32-bit ints for 64-bit range)
        final high = rng.nextInt(100);
        final low = rng.nextInt(1 << 30);
        final size = i == 0 ? 0 : (high * (1 << 30) + low);
        final count = chunker.chunkCount(size);

        if (size == 0) {
          expect(count, 0);
          expect(chunker.ranges(size), isEmpty);
        } else {
          expect(count, (size + cs - 1) ~/ cs);
          // Check arbitrary random index
          final sampleIdx = rng.nextInt(count);
          final r = chunker.range(size, sampleIdx);
          expect(r.index, sampleIdx);
          expect(r.start, sampleIdx * cs);
          if (sampleIdx < count - 1) {
            expect(r.length, cs);
            expect(r.end, (sampleIdx + 1) * cs);
          } else {
            expect(r.end, size);
            expect(r.length, size - (sampleIdx * cs));
          }
        }
      }
    });
  });

  group('2. Filename Sanitizer & Path Traversal Property Tests (FR-09, T7)', () {
    const posixBase = '/home/user/downloads';
    const winBase = r'C:\Users\User\Downloads';

    final traversalCorpus = <String>[
      '..',
      '.',
      '...',
      '/',
      '\\',
      '//',
      '\\\\',
      '../',
      '..\\',
      '/..',
      '\\..',
      '../../',
      '..\\..\\',
      '../../../etc/passwd',
      '../../../../../../../../../../../../etc/shadow',
      r'..\..\..\..\..\..\..\..\..\..\..\..\Windows\System32\cmd.exe',
      '/etc/passwd',
      '/root/.ssh/id_rsa',
      r'C:\Windows\System32\drivers\etc\hosts',
      r'\\?\C:\Windows\System32',
      r'\\server\share\file.txt',
      'foo/../../bar',
      r'foo\..\..\bar',
      'foo/bar/../../../baz',
      'CON',
      'con',
      'PRN',
      'prn',
      'AUX',
      'aux',
      'NUL',
      'nul',
      'COM1',
      'com9',
      'LPT1',
      'lpt9',
      'con.txt',
      'nul.tar.gz',
      'aux.pdf',
      'file.',
      'file...',
      'file ',
      'file  ',
      'file \t',
      'file\r\n',
      'file\u0000name.txt',
      'file\u001FName.txt',
      'bidi_\u202E_reversed.exe',
      'bidi_\u202D_override.txt',
      'zero_width_\u200B_space.png',
      'bom_\uFEFF_marker.dat',
      'line_\u2028_separator',
    ];

    test(
      'corpus traversal names always resolve strictly inside download dir',
      () {
        for (final malicious in traversalCorpus) {
          String? sanitized;
          try {
            sanitized = sanitizeFileName(malicious);
          } on LsException catch (e) {
            expect(e.code, LsErrorCode.badRequest);
            continue;
          }

          expect(sanitized, isNotNull);
          expect(sanitized, isNotEmpty);
          expect(
            sanitized.contains('/'),
            isFalse,
            reason: '$sanitized contains slash',
          );
          expect(
            sanitized.contains('\\'),
            isFalse,
            reason: '$sanitized contains backslash',
          );

          // Check POSIX containment
          final posixJoined = p.posix.join(posixBase, sanitized);
          expect(
            p.posix.isWithin(posixBase, posixJoined),
            isTrue,
            reason: 'POSIX path escape: $posixJoined',
          );

          // Check Windows containment
          final winJoined = p.windows.join(winBase, sanitized);
          expect(
            p.windows.isWithin(winBase, winJoined),
            isTrue,
            reason: 'Win32 path escape: $winJoined',
          );

          // Check Windows reserved names
          final stem = sanitized.split('.').first.toUpperCase();
          expect(
            {
              'CON',
              'PRN',
              'AUX',
              'NUL',
              'COM1',
              'COM2',
              'COM3',
              'COM4',
              'COM5',
              'COM6',
              'COM7',
              'COM8',
              'COM9',
              'LPT1',
              'LPT2',
              'LPT3',
              'LPT4',
              'LPT5',
              'LPT6',
              'LPT7',
              'LPT8',
              'LPT9',
            }.contains(stem),
            isFalse,
            reason: 'Reserved DOS name survived: $sanitized',
          );

          // Check trailing dot/space
          expect(
            sanitized.endsWith('.'),
            isFalse,
            reason: 'Trailing dot survived: $sanitized',
          );
          expect(
            sanitized.endsWith(' '),
            isFalse,
            reason: 'Trailing space survived: $sanitized',
          );
        }
      },
    );

    test('random filename mutation fuzzer (1000 iterations)', () {
      final rng = Random(2026);
      final alphabet =
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- /\\:<>|?*"\x00\x01\x1F\u202E\u200B';

      for (var i = 0; i < 1000; i++) {
        final len = rng.nextInt(64) + 1;
        final buffer = StringBuffer();
        for (var j = 0; j < len; j++) {
          buffer.write(alphabet[rng.nextInt(alphabet.length)]);
        }
        final raw = buffer.toString();

        String? sanitized;
        try {
          sanitized = sanitizeFileName(raw);
        } on LsException catch (e) {
          expect(e.code, LsErrorCode.badRequest);
          continue;
        } catch (e) {
          fail('Unexpected exception type ${e.runtimeType} for input: $raw');
        }

        expect(sanitized, isNotNull);
        expect(sanitized, isNotEmpty);
        expect(sanitized.contains('/'), isFalse);
        expect(sanitized.contains('\\'), isFalse);

        final posixJoined = p.posix.join(posixBase, sanitized);
        expect(p.posix.isWithin(posixBase, posixJoined), isTrue);

        final winJoined = p.windows.join(winBase, sanitized);
        expect(p.windows.isWithin(winBase, winJoined), isTrue);
      }
    });
  });

  group('3. Discovery Announce Codec Property Fuzzer (LSP-1 §4.2)', () {
    test(
      'decodeAnnounce never throws and validates round trips (1000 iterations)',
      () {
        final rng = Random(42);

        for (var i = 0; i < 1000; i++) {
          final byteLen = rng.nextInt(1500);
          final bytes = Uint8List(byteLen);
          for (var j = 0; j < byteLen; j++) {
            bytes[j] = rng.nextInt(256);
          }

          AnnounceMessage? msg;
          expect(
            () {
              msg = decodeAnnounce(bytes);
            },
            returnsNormally,
            reason: 'decodeAnnounce threw on random bytes',
          );

          final m = msg;
          if (m != null) {
            expect(m.info.port, inInclusiveRange(0, 65535));
            expect(
              m.info.fingerprint,
              equals(m.info.fingerprint.toUpperCase()),
            );

            // Verify re-encoding succeeds
            final reEncoded = encodeAnnounce(m.info, announce: m.announce);
            expect(reEncoded.length, lessThanOrEqualTo(kMaxAnnounceBytes));

            final reDecoded = decodeAnnounce(reEncoded);
            expect(reDecoded, isNotNull);
            if (reDecoded != null) {
              expect(reDecoded.announce, m.announce);
              expect(reDecoded.info.fingerprint, m.info.fingerprint);
            }
          }
        }
      },
    );
  });

  group('4. Manifest & Wire DTO Property Fuzzer (spec §4.3)', () {
    test('FileItem and SessionRequest tolerance of unknown fields and malformed data', () {
      final validFileJson = <String, Object?>{
        'fileId': 'f_1',
        'fileName': 'document.pdf',
        'size': 1048576,
        'chunkCount': 1,
        'mime': 'application/pdf',
        'sha256': 'a' * 64,
        'modified': '2026-11-07T20:00:00.000Z',
        'unknown_extension_field': 'tolerated_value',
        'nested_extra': {
          'level2': 42,
          'level3': [1, 2, 3],
        },
      };

      // Tolerates unknown fields
      final item = FileItem.fromJson(validFileJson);
      expect(item.fileId, 'f_1');
      expect(item.fileName, 'document.pdf');
      expect(item.size, 1048576);

      // Round trip preserves primary fields
      final serialized = item.toJson();
      final roundTrip = FileItem.fromJson(serialized);
      expect(roundTrip.fileId, item.fileId);
      expect(roundTrip.fileName, item.fileName);
      expect(roundTrip.size, item.size);

      // Fuzz invalid types: throws TypeError or FormatException, never hangs
      final invalidCases = <Map<String, Object?>>[
        {...validFileJson, 'fileId': null},
        {...validFileJson, 'size': 'not_a_number'},
        {...validFileJson, 'chunkCount': -1.5},
        {...validFileJson, 'modified': 'invalid-date-string'},
      ];

      for (final invalid in invalidCases) {
        expect(
          () => FileItem.fromJson(invalid),
          throwsA(anyOf(isA<TypeError>(), isA<FormatException>())),
        );
      }
    });

    test('SessionRequest unknown-field tolerance at all levels', () {
      final validRequestJson = <String, Object?>{
        'sender': {
          'deviceId': 'd-1',
          'alias': 'Alice',
          'platform': 'linux',
          'deviceType': 'desktop',
          'fingerprint': 'F' * 64,
          'port': 53318,
          'extra_device_prop': true,
        },
        'files': [
          {
            'fileId': 'f_1',
            'fileName': 'test.txt',
            'size': 10,
            'chunkCount': 1,
            'extra_file_prop': 123,
          },
        ],
        'totalSize': 10,
        'pin': '123456',
        'unknown_top_level_prop': 'should_be_ignored',
      };

      final req = SessionRequest.fromJson(validRequestJson);
      expect(req.sender.alias, 'Alice');
      expect(req.files.length, 1);
      expect(req.totalSize, 10);
      expect(req.pin, '123456');

      final json = req.toJson();
      final req2 = SessionRequest.fromJson(json);
      expect(req2.sender.alias, req.sender.alias);
      expect(req2.totalSize, req.totalSize);
    });
  });

  group(
    '5. Request Headers Fuzzing (X-Chunk-Sha256, Content-Length, Range)',
    () {
      test('X-Chunk-Sha256 header validation properties', () {
        final validDigest = 'abcdef0123456789' * 4; // 64 hex
        final regex = RegExp(r'^[0-9a-f]{64}$');

        expect(regex.hasMatch(validDigest), isTrue);

        final malformedDigests = <String>[
          '',
          'abcdef', // < 64
          '${validDigest}a', // 65 chars
          validDigest.toUpperCase(), // uppercase rejected by strict wire rule
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg', // 'g' non-hex
          '../../../etc/passwd',
          ' ',
        ];

        for (final bad in malformedDigests) {
          expect(
            regex.hasMatch(bad),
            isFalse,
            reason: 'Malformed digest unexpectedly passed: $bad',
          );
        }
      });

      test('Content-Length parsing boundaries and invalid forms', () {
        int? parseContentLength(String header) {
          final trimmed = header.trim();
          if (!RegExp(r'^[0-9]+$').hasMatch(trimmed)) return null;
          return int.tryParse(trimmed);
        }

        expect(parseContentLength('0'), 0);
        expect(parseContentLength('4194304'), 4194304);
        expect(parseContentLength('  1024  '), 1024);

        final invalidLengths = <String>[
          '-1',
          '-100',
          'abc',
          '123.45',
          '1e6',
          '0x10',
          '',
          '   ',
        ];

        for (final bad in invalidLengths) {
          expect(parseContentLength(bad), isNull);
        }
      });

      test('Range header syntax and interval properties', () {
        (int, int)? parseRange(String header) {
          final match = RegExp(r'^bytes=(\d+)-(\d+)$')
              .firstMatch(header.trim());
          if (match == null) return null;
          final start = int.parse(match.group(1)!);
          final end = int.parse(match.group(2)!);
          if (start > end) return null; // Inverted range
          return (start, end);
        }

        expect(parseRange('bytes=0-4194303'), (0, 4194303));
        expect(parseRange('bytes=100-200'), (100, 200));

        // Inverted range
        expect(parseRange('bytes=200-100'), isNull);
        // Malformed strings
        expect(parseRange('bytes=-100'), isNull);
        expect(parseRange('bytes=100-'), isNull);
        expect(parseRange('items=0-100'), isNull);
        expect(parseRange('bytes=abc-def'), isNull);
      });
    },
  );

  group('6. /state Response Shape Fuzzer (FileState)', () {
    test('FileState JSON parsing and round-trip properties', () {
      final validStateJson = <String, Object?>{
        'receivedRanges': [
          [0, 100],
          [200, 300],
        ],
        'chunkCount': 5,
        'extra_state_prop': 'ignored',
      };

      final state = FileState.fromJson(validStateJson);
      expect(state.chunkCount, 5);
      expect(state.receivedRanges.length, 2);
      expect(state.receivedRanges[0], [0, 100]);
      expect(state.receivedRanges[1], [200, 300]);

      final json = state.toJson();
      final state2 = FileState.fromJson(json);
      expect(state2.chunkCount, 5);
      expect(state2.receivedRanges.length, 2);

      // Inverted interval detection
      bool isValidIntervals(List<List<int>> ranges) {
        for (final r in ranges) {
          if (r.length != 2) return false;
          if (r[0] > r[1] || r[0] < 0) return false;
        }
        return true;
      }

      expect(isValidIntervals(state.receivedRanges), isTrue);
      expect(
        isValidIntervals([
          [100, 50],
        ]),
        isFalse,
      );
      expect(
        isValidIntervals([
          [-1, 50],
        ]),
        isFalse,
      );
    });
  });

  group('7. ShareLink / URI Parser Fuzzing (FR-14, H2)', () {
    test('ShareLink.parse fuzzer throws exclusively ShareLinkException or produces valid link (1000 iterations)', () {
      final rng = Random(777);
      final alphabet =
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_&=?#/.:%[]@';

      for (var i = 0; i < 1000; i++) {
        final len = rng.nextInt(300) + 1;
        final buffer = StringBuffer();
        buffer.write(rng.nextBool() ? 'https://' : 'libreshare://r?');
        for (var j = 0; j < len; j++) {
          buffer.write(alphabet[rng.nextInt(alphabet.length)]);
        }
        final raw = buffer.toString();

        ShareLink? link;
        try {
          link = ShareLink.parse(raw, allowDeveloperHosts: rng.nextBool());
        } on ShareLinkException {
          // Expected structured exception
        } catch (e) {
          fail(
            'ShareLink.parse threw unexpected exception ${e.runtimeType}: $e for input: $raw',
          );
        }

        if (link != null) {
          expect(link.version, 1);
          expect(link.host, isNotEmpty);
          expect(link.token.length, 16);
          expect(link.rootKey.length, 32);

          // Verify round trip
          final encoded = link.encode();
          final parsed = ShareLink.parse(encoded, allowDeveloperHosts: true);
          expect(parsed.host, link.host);
          expect(parsed.token, link.token);
          expect(parsed.rootKey, link.rootKey);
        }
      }
    });
  });
}
