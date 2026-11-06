import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

class _MockFastNativeSha256Provider implements Sha256Provider {
  int hashBytesCalls = 0;
  int hashStreamCalls = 0;

  @override
  String hashBytes(List<int> bytes) {
    hashBytesCalls++;
    return 'mock_fast_${bytes.length}';
  }

  @override
  Future<String> hashStream(Stream<List<int>> input) async {
    hashStreamCalls++;
    var len = 0;
    await for (final b in input) {
      len += b.length;
    }
    return 'mock_stream_$len';
  }
}

void main() {
  group('Sha256Provider injection & acceleration seam', () {
    final originalProvider = activeSha256Provider;

    tearDown(() {
      activeSha256Provider = originalProvider;
    });

    test('defaults to PureDartSha256Provider', () {
      expect(activeSha256Provider, isA<PureDartSha256Provider>());
      final digest = sha256OfBytes(utf8.encode('hello world'));
      expect(
        digest,
        'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
      );
    });

    test('custom/native Sha256Provider intercepts sha256OfBytes and sha256OfStream', () async {
      final mock = _MockFastNativeSha256Provider();
      activeSha256Provider = mock;

      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final bHash = sha256OfBytes(data);
      expect(bHash, equals('mock_fast_5'));
      expect(mock.hashBytesCalls, equals(1));

      final sHash = await sha256OfStream(Stream.value(data));
      expect(sHash, equals('mock_stream_5'));
      expect(mock.hashStreamCalls, equals(1));
    });
  });
}
