/// SHA-256 helpers (spec §4.3, §8): streamed so memory stays constant, and the
/// whole-file variant runs in a background [Isolate] so it never blocks the
/// caller's event loop.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'chunker.dart';

/// SHA-256 of the empty byte string (lowercase hex).
const String kSha256Empty =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// Pluggable SHA-256 provider interface for hardware acceleration (e.g. in Flutter app).
abstract interface class Sha256Provider {
  /// Synchronous or fast SHA-256 of in-memory bytes, lowercase hex.
  String hashBytes(List<int> bytes);

  /// Incremental or streamed SHA-256 of a stream of bytes, lowercase hex.
  Future<String> hashStream(Stream<List<int>> input);
}

/// Standard pure-Dart SHA-256 provider using package:crypto.
class PureDartSha256Provider implements Sha256Provider {
  const PureDartSha256Provider();

  @override
  String hashBytes(List<int> bytes) => sha256.convert(bytes).toString();

  @override
  Future<String> hashStream(Stream<List<int>> input) async =>
      (await _hashStream(input)).hex;
}

/// Active global SHA-256 provider. Defaults to pure Dart; app layer may inject
/// a platform-accelerated provider.
Sha256Provider activeSha256Provider = const PureDartSha256Provider();

/// SHA-256 of an in-memory byte list, lowercase hex.
String sha256OfBytes(List<int> bytes) => activeSha256Provider.hashBytes(bytes);

/// SHA-256 of [input], consuming it incrementally (memory bounded by the
/// stream's own chunk size). Returns lowercase hex.
Future<String> sha256OfStream(Stream<List<int>> input) =>
    activeSha256Provider.hashStream(input);

/// SHA-256 of the whole [file], streamed from disk inside a background
/// [Isolate] (constant memory, event loop of the caller stays free).
/// Throws [FileSystemException] if the file cannot be read.
Future<String> sha256OfFile(File file) {
  // Capture only the path (a String): `File` objects are not guaranteed to be
  // sendable across isolates.
  final path = file.path;
  return Isolate.run(() => _sha256OfPath(path));
}

/// Chunks up to this size are hashed on the calling isolate (spawning costs
/// more than hashing); larger ones go to a background isolate so several chunks
/// can be hashed on different cores while the caller keeps doing network I/O.
const int _kInlineChunkHashMax = 256 * 1024;

/// SHA-256 of the bytes of [range] in [file], streamed (never buffers the
/// chunk). Throws [FileSystemException] if the file holds fewer than
/// `range.length` bytes at that offset (i.e. it changed after the manifest was
/// built).
Future<String> sha256OfChunk(File file, ChunkRange range) {
  final path = file.path;
  final start = range.start;
  final end = range.end;
  final index = range.index;
  if (range.length <= _kInlineChunkHashMax) {
    return _sha256OfSlice(path, start, end, index);
  }
  return Isolate.run(() => _sha256OfSlice(path, start, end, index));
}

Future<String> _sha256OfSlice(
  String path,
  int start,
  int end,
  int index,
) async {
  final r = await _hashStream(File(path).openRead(start, end));
  if (r.length != end - start) {
    throw FileSystemException(
      'File shorter than expected: chunk $index has ${r.length} of '
      '${end - start} bytes',
      path,
    );
  }
  return r.hex;
}

Future<String> _sha256OfPath(String path) async =>
    (await _hashStream(File(path).openRead())).hex;

Future<({String hex, int length})> _hashStream(Stream<List<int>> input) async {
  final out = _DigestSink();
  final conv = sha256.startChunkedConversion(out);
  var length = 0;
  try {
    await for (final part in input) {
      conv.add(part);
      length += part.length;
    }
  } finally {
    conv.close();
  }
  return (hex: out.digest.toString(), length: length);
}

class _DigestSink implements Sink<Digest> {
  late final Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
