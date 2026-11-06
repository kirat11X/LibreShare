// ignore_for_file: avoid_print, depend_on_referenced_packages
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:libreshare_core/libreshare_core.dart';

/// Stage profiling metrics record.
class StageMetric {
  const StageMetric({
    required this.name,
    required this.elapsedMs,
    required this.throughputMibS,
    this.notes = '',
  });

  final String name;
  final double elapsedMs;
  final double throughputMibS;
  final String notes;
}

class _BenchmarkDigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

void main(List<String> rawArgs) async {
  final parser = ArgParser()
    ..addOption(
      'size-mib',
      abbr: 's',
      defaultsTo: '100',
      help: 'File size in MiB',
    )
    ..addOption(
      'chunk-size-mib',
      abbr: 'c',
      defaultsTo: '4',
      help: 'Chunk size in MiB',
    )
    ..addOption(
      'port',
      abbr: 'p',
      defaultsTo: '53950',
      help: 'Loopback port for transport tests',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage');

  final args = parser.parse(rawArgs);
  if (args['help'] as bool) {
    print(parser.usage);
    exit(0);
  }

  final sizeMib = int.parse(args['size-mib'] as String);
  final chunkSizeMib = int.parse(args['chunk-size-mib'] as String);
  final port = int.parse(args['port'] as String);
  final totalBytes = sizeMib * 1024 * 1024;
  final chunkBytes = chunkSizeMib * 1024 * 1024;
  final chunkCount = (totalBytes + chunkBytes - 1) ~/ chunkBytes;

  print('=== LibreShare Throughput & Latency Profiler (Spike S4-A) ===');
  print(
    'Payload: $sizeMib MiB ($totalBytes bytes), Chunks: $chunkCount x $chunkSizeMib MiB',
  );
  print(
    'System: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
  );
  print('Dart SDK: ${Platform.version}');

  final tempDir = Directory.systemTemp.createTempSync('libreshare_bench_');
  try {
    final srcFile = File('${tempDir.path}/src_payload.bin');
    final dstFile = File('${tempDir.path}/dst_payload.bin');

    // 0. Preparation: write source random payload
    final prepSw = Stopwatch()..start();
    stdout.write('Generating $sizeMib MiB test payload... ');
    final random = Random(42);
    final raf = srcFile.openSync(mode: FileMode.write);
    final buffer = Uint8List(chunkBytes);
    for (var i = 0; i < chunkBytes; i += 4) {
      final v = random.nextInt(0xFFFFFFFF);
      buffer[i] = v & 0xFF;
      if (i + 1 < chunkBytes) buffer[i + 1] = (v >> 8) & 0xFF;
      if (i + 2 < chunkBytes) buffer[i + 2] = (v >> 16) & 0xFF;
      if (i + 3 < chunkBytes) buffer[i + 3] = (v >> 24) & 0xFF;
    }
    for (var c = 0; c < chunkCount; c++) {
      raf.writeFromSync(buffer);
    }
    raf.closeSync();
    prepSw.stop();
    print('done (${prepSw.elapsedMilliseconds} ms).\n');

    final results = <StageMetric>[];

    // =========================================================================
    // Stage 1: Disk Read
    // =========================================================================
    stdout.write(
      'Stage 1: Measuring Sender Disk Read (sequential 4 MiB blocks)... ',
    );
    final s1Sw = Stopwatch()..start();
    final readRaf = srcFile.openSync(mode: FileMode.read);
    var bytesRead = 0;
    final readBuf = Uint8List(chunkBytes);
    for (var c = 0; c < chunkCount; c++) {
      final n = readRaf.readIntoSync(readBuf);
      bytesRead += n;
    }
    readRaf.closeSync();
    s1Sw.stop();
    final s1Ms = s1Sw.elapsedMicroseconds / 1000.0;
    final s1Rate = (bytesRead / (1024 * 1024)) / (s1Ms / 1000.0);
    print('${s1Ms.toStringAsFixed(1)} ms (${s1Rate.toStringAsFixed(1)} MiB/s)');
    results.add(
      StageMetric(
        name: '1. Sender Disk Read',
        elapsedMs: s1Ms,
        throughputMibS: s1Rate,
      ),
    );

    // =========================================================================
    // Stage 2: Sender Chunk Hashing (Pure-Dart SHA-256)
    // =========================================================================
    stdout.write(
      'Stage 2a: Measuring Sender Chunk Hashing (Inline Pure-Dart)... ',
    );
    final s2aSw = Stopwatch()..start();
    for (var c = 0; c < chunkCount; c++) {
      sha256.convert(buffer);
    }
    s2aSw.stop();
    final s2aMs = s2aSw.elapsedMicroseconds / 1000.0;
    final s2aRate = sizeMib / (s2aMs / 1000.0);
    print(
      '${s2aMs.toStringAsFixed(1)} ms (${s2aRate.toStringAsFixed(1)} MiB/s)',
    );

    stdout.write(
      'Stage 2b: Measuring Sender Chunk Hashing (Isolate.run per chunk)... ',
    );
    final s2bSw = Stopwatch()..start();
    for (var c = 0; c < chunkCount; c++) {
      await Isolate.run(() => sha256.convert(buffer).toString());
    }
    s2bSw.stop();
    final s2bMs = s2bSw.elapsedMicroseconds / 1000.0;
    final s2bRate = sizeMib / (s2bMs / 1000.0);
    print(
      '${s2bMs.toStringAsFixed(1)} ms (${s2bRate.toStringAsFixed(1)} MiB/s)',
    );
    results.add(
      StageMetric(
        name: '2. Sender Chunk Hashing (Pure Dart)',
        elapsedMs: s2aMs,
        throughputMibS: s2aRate,
        notes:
            'Isolate.run overhead adds ${(s2bMs - s2aMs).toStringAsFixed(1)} ms total',
      ),
    );

    // =========================================================================
    // Stage 3: Transport Overhead (Loopback Plain vs TLS 1.3)
    // =========================================================================
    // 3a. Plaintext HTTP Loopback
    stdout.write(
      'Stage 3a: Measuring Plaintext HTTP Transport (In-memory loopback)... ',
    );
    final plainServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    plainServer.listen((req) async {
      await req.fold<int>(0, (sum, p) => sum + p.length);
      final resp = req.response;
      resp.statusCode = HttpStatus.ok;
      await resp.close();
    });

    final plainClient = HttpClient()..findProxy = ((_) => 'DIRECT');
    final s3aSw = Stopwatch()..start();
    for (var c = 0; c < chunkCount; c++) {
      final req = await plainClient.openUrl(
        'PUT',
        Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: plainServer.port,
          path: '/chunk/$c',
        ),
      );
      req.contentLength = chunkBytes;
      await req.addStream(Stream.value(buffer));
      final resp = await req.close();
      await resp.drain<void>();
    }
    s3aSw.stop();
    await plainServer.close(force: true);
    plainClient.close(force: true);
    final s3aMs = s3aSw.elapsedMicroseconds / 1000.0;
    final s3aRate = sizeMib / (s3aMs / 1000.0);
    print(
      '${s3aMs.toStringAsFixed(1)} ms (${s3aRate.toStringAsFixed(1)} MiB/s)',
    );

    // 3b. TLS 1.3 HTTPS Loopback
    stdout.write(
      'Stage 3b: Measuring TLS 1.3 HTTPS Transport (In-memory loopback)... ',
    );
    final secDir = Directory('${tempDir.path}/sec');
    await secDir.create();
    final wiring = await SecurityWiring.open(
      directory: secDir,
      deviceId: 'bench-device-id-12345678',
    );
    final serverCtx = buildServerContext(wiring.identity);
    final clientCtx = buildClientContext();

    final secureServer = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      port == 0 ? 0 : port + 1,
      serverCtx,
    );
    secureServer.listen((req) async {
      await req.fold<int>(0, (sum, p) => sum + p.length);
      final resp = req.response;
      resp.statusCode = HttpStatus.ok;
      await resp.close();
    });

    final secureClient = HttpClient(context: clientCtx)
      ..findProxy = ((_) => 'DIRECT');
    secureClient.badCertificateCallback = (cert, host, p) => true;

    final s3bSw = Stopwatch()..start();
    for (var c = 0; c < chunkCount; c++) {
      final req = await secureClient.openUrl(
        'PUT',
        Uri(
          scheme: 'https',
          host: '127.0.0.1',
          port: secureServer.port,
          path: '/chunk/$c',
        ),
      );
      req.contentLength = chunkBytes;
      await req.addStream(Stream.value(buffer));
      final resp = await req.close();
      await resp.drain<void>();
    }
    s3bSw.stop();
    await secureServer.close(force: true);
    secureClient.close(force: true);
    await wiring.close();
    final s3bMs = s3bSw.elapsedMicroseconds / 1000.0;
    final s3bRate = sizeMib / (s3bMs / 1000.0);
    print(
      '${s3bMs.toStringAsFixed(1)} ms (${s3bRate.toStringAsFixed(1)} MiB/s)',
    );
    results.add(
      StageMetric(
        name: '3. Transport (TLS 1.3 Loopback)',
        elapsedMs: s3bMs,
        throughputMibS: s3bRate,
        notes:
            'Plaintext HTTP: ${s3aMs.toStringAsFixed(1)} ms (${s3aRate.toStringAsFixed(1)} MiB/s)',
      ),
    );

    // =========================================================================
    // Stage 4: Receiver Disk Write
    // =========================================================================
    stdout.write(
      'Stage 4: Measuring Receiver Disk Write (RandomAccessFile setPosition+writeFrom)... ',
    );
    final s4Sw = Stopwatch()..start();
    final writeRaf = dstFile.openSync(mode: FileMode.write);
    for (var c = 0; c < chunkCount; c++) {
      writeRaf.setPositionSync(c * chunkBytes);
      writeRaf.writeFromSync(buffer);
    }
    writeRaf.flushSync();
    writeRaf.closeSync();
    s4Sw.stop();
    final s4Ms = s4Sw.elapsedMicroseconds / 1000.0;
    final s4Rate = sizeMib / (s4Ms / 1000.0);
    print('${s4Ms.toStringAsFixed(1)} ms (${s4Rate.toStringAsFixed(1)} MiB/s)');
    results.add(
      StageMetric(
        name: '4. Receiver Disk Write',
        elapsedMs: s4Ms,
        throughputMibS: s4Rate,
      ),
    );

    // =========================================================================
    // Stage 5: Receiver Chunk Validation
    // =========================================================================
    stdout.write(
      'Stage 5: Measuring Receiver Chunk Validation (Streamed Chunked Hashing)... ',
    );
    final s5Sw = Stopwatch()..start();
    for (var c = 0; c < chunkCount; c++) {
      final sink = _BenchmarkDigestSink();
      final conversion = sha256.startChunkedConversion(sink);
      const pieceSize = 64 * 1024;
      for (var offset = 0; offset < chunkBytes; offset += pieceSize) {
        conversion.add(
          Uint8List.sublistView(buffer, offset, offset + pieceSize),
        );
      }
      conversion.close();
      final _ = sink.value.toString();
    }
    s5Sw.stop();
    final s5Ms = s5Sw.elapsedMicroseconds / 1000.0;
    final s5Rate = sizeMib / (s5Ms / 1000.0);
    print('${s5Ms.toStringAsFixed(1)} ms (${s5Rate.toStringAsFixed(1)} MiB/s)');
    results.add(
      StageMetric(
        name: '5. Receiver Chunk Validation',
        elapsedMs: s5Ms,
        throughputMibS: s5Rate,
      ),
    );

    // =========================================================================
    // Stage 6: Receiver Whole-File SHA-256
    // =========================================================================
    stdout.write(
      'Stage 6: Measuring Receiver Whole-File SHA-256 (Isolate stream read)... ',
    );
    final s6Sw = Stopwatch()..start();
    final wholeHash = await sha256OfFile(dstFile);
    s6Sw.stop();
    final s6Ms = s6Sw.elapsedMicroseconds / 1000.0;
    final s6Rate = sizeMib / (s6Ms / 1000.0);
    print('${s6Ms.toStringAsFixed(1)} ms (${s6Rate.toStringAsFixed(1)} MiB/s)');
    results.add(
      StageMetric(
        name: '6. Receiver Whole-File SHA-256',
        elapsedMs: s6Ms,
        throughputMibS: s6Rate,
        notes: 'Digest: ${wholeHash.substring(0, 16)}...',
      ),
    );

    // =========================================================================
    // Overall Summary and Analysis
    // =========================================================================
    print(
      '\n=========================================================================',
    );
    print(
      'STAGE-BY-STAGE LATENCY & THROUGHPUT BREAKDOWN ($sizeMib MiB Payload)',
    );
    print(
      '=========================================================================',
    );
    final totalSerializedMs = results.fold<double>(
      0.0,
      (sum, m) => sum + m.elapsedMs,
    );
    final projectedThroughput = sizeMib / (totalSerializedMs / 1000.0);

    print(
      '${'Stage'.padRight(36)} | '
      '${'Time (ms)'.padLeft(10)} | '
      '${'Speed (MiB/s)'.padLeft(14)} | '
      '${'% Total'.padLeft(8)} | '
      'Notes',
    );
    print('-' * 95);
    for (final m in results) {
      final pct = (m.elapsedMs / totalSerializedMs) * 100.0;
      print(
        '${m.name.padRight(36)} | '
        '${m.elapsedMs.toStringAsFixed(1).padLeft(10)} | '
        '${m.throughputMibS.toStringAsFixed(1).padLeft(14)} | '
        '${pct.toStringAsFixed(1).padLeft(7)}% | '
        '${m.notes}',
      );
    }
    print('-' * 95);
    print(
      '${'TOTAL SERIALIZED LATENCY'.padRight(36)} | '
      '${totalSerializedMs.toStringAsFixed(1).padLeft(10)} | '
      '${projectedThroughput.toStringAsFixed(1).padLeft(14)} | '
      ' 100.0% | '
      'Projected end-to-end serialized rate',
    );
    print(
      '=========================================================================\n',
    );

    final totalHashingMs = s2aMs + s5Ms + s6Ms;
    final hashingPct = (totalHashingMs / totalSerializedMs) * 100.0;
    final totalIoMs = s1Ms + s4Ms;
    final ioPct = (totalIoMs / totalSerializedMs) * 100.0;
    final transportPct = (s3bMs / totalSerializedMs) * 100.0;

    print('Category Analysis:');
    print(
      '  - SHA-256 Hashing (Stages 2, 5, 6): ${totalHashingMs.toStringAsFixed(1)} ms (${hashingPct.toStringAsFixed(1)}% of total time)',
    );
    print(
      '  - Disk I/O (Stages 1, 4):          ${totalIoMs.toStringAsFixed(1)} ms (${ioPct.toStringAsFixed(1)}% of total time)',
    );
    print(
      '  - TLS & Network Transport (Stage 3): ${s3bMs.toStringAsFixed(1)} ms (${transportPct.toStringAsFixed(1)}% of total time)',
    );
    print('');
    print('DOMINANT COST IDENTIFICATION:');
    if (hashingPct > 50) {
      print(
        '  Pure-Dart SHA-256 hashing is the DOMINANT BOTTLENECK (${hashingPct.toStringAsFixed(1)}% of latency).\n'
        '  The 4 serialized SHA-256 passes (sender chunk, receiver chunk, receiver whole-file, sender whole-file)\n'
        '  fundamentally cap single-core throughput to ~${(s2aRate / 3.0).toStringAsFixed(1)} - ${(s2aRate / 4.0).toStringAsFixed(1)} MiB/s.',
      );
    } else {
      print('  Disk I/O or Transport dominates.');
    }
  } finally {
    tempDir.deleteSync(recursive: true);
  }
}
