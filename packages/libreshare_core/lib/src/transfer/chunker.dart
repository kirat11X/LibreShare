/// Chunk math + streaming (spec §4.4). 64-bit offsets; no I/O beyond openRead.
library;

import 'dart:io';

import '../protocol.dart';

class ChunkRange {
  const ChunkRange(this.index, this.start, this.end);
  final int index;
  final int start; // inclusive byte offset
  final int end; // exclusive byte offset
  int get length => end - start;
  @override
  String toString() => 'ChunkRange($index, [$start,$end))';
}

class Chunker {
  const Chunker([this.chunkSize = kChunkSize]);
  final int chunkSize;

  /// Number of chunks for [size] bytes. A 0-byte file has 0 chunks.
  int chunkCount(int size) =>
      size <= 0 ? 0 : (size + chunkSize - 1) ~/ chunkSize;

  ChunkRange range(int size, int index) {
    final count = chunkCount(size);
    if (index < 0 || index >= count) {
      throw RangeError.range(index, 0, count - 1, 'index');
    }
    final start = index * chunkSize;
    final end = start + chunkSize < size ? start + chunkSize : size;
    return ChunkRange(index, start, end);
  }

  Iterable<ChunkRange> ranges(int size) sync* {
    for (var i = 0; i < chunkCount(size); i++) {
      yield range(size, i);
    }
  }

  /// Streams exactly the bytes of [r] from [file] (memory bounded by IO buffers).
  Stream<List<int>> openChunk(File file, ChunkRange r) =>
      file.openRead(r.start, r.end);
}
