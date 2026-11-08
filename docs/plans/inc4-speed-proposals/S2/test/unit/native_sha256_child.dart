// Helper process for native_sha256_test.dart (NOT a test: no _test suffix).
// Prints what installBestSha256Provider() chose in a process whose
// environment the parent controls (LS_NO_NATIVE_SHA).
//
// Mode `rss pure|native`: runs 10,000 start/dispose cycles in this otherwise
// idle process and prints the RSS growth in bytes (a shared test VM has
// parallel isolates, so the parent cannot measure this itself).
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_core/src/transfer/hashing.dart';
import 'package:libreshare_core/src/transfer/native_sha256.dart';

Future<void> main(List<String> args) async {
  if (args.length == 2 && args[0] == 'rss') {
    await _rss(args[1]);
    return;
  }
  final returned = installBestSha256Provider();
  final inc = newSha256Incremental()..add(const [97, 98, 99]);
  final abc = inc.finishHex();
  inc.dispose();
  // ignore: avoid_print
  print(
    'ACTIVE=${activeSha256Provider is PureDartSha256Provider ? 'pure' : 'other'}'
    ' RETURNED_IS_ACTIVE=${identical(returned, activeSha256Provider)}'
    ' ABC=$abc',
  );
}

Future<void> _rss(String which) async {
  final IncrementalSha256Provider? p = which == 'native'
      ? tryLoadNativeSha256()
      : const PureDartSha256Provider();
  if (p == null) {
    // ignore: avoid_print
    print('RSS_GROWTH=NONE');
    return;
  }
  final buf = Uint8List(which == 'native' ? 64 * 1024 : 1024);
  final r = Random(7);
  for (var i = 0; i < buf.length; i++) {
    buf[i] = r.nextInt(256);
  }
  void cycles(int count) {
    for (var i = 0; i < count; i++) {
      final inc = p.startIncremental()..add(buf);
      if (i.isEven) inc.finishHex();
      inc.dispose();
    }
  }

  Future<int> settledRss() async {
    // let the VM collect garbage: allocate and drop, then wait a little
    for (var k = 0; k < 4; k++) {
      final junk = <Uint8List>[
        for (var i = 0; i < 64; i++) Uint8List(256 * 1024),
      ];
      junk.clear();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return ProcessInfo.currentRss;
  }

  cycles(300); // warm-up
  final before = await settledRss();
  cycles(10000);
  final after = await settledRss();
  // ignore: avoid_print
  print('RSS_GROWTH=${after - before}');
}
