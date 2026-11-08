// Child process for the Inc 4 restart tests: a plaintext receiver engine that
// the test kills with SIGKILL. Prints "READY <port>" once listening.
//   dart test/helpers/inc4_receiver_main.dart --dir D [--port P]
//       [--clock-offset-seconds N]
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';

class _OffsetClock implements Clock {
  _OffsetClock(this.offset);
  final Duration offset;
  @override
  DateTime now() => DateTime.now().add(offset);
}

Future<void> main(List<String> args) async {
  String? dir;
  var port = 0;
  var offset = 0;
  for (var i = 0; i + 1 < args.length; i += 2) {
    switch (args[i]) {
      case '--dir':
        dir = args[i + 1];
      case '--port':
        port = int.parse(args[i + 1]);
      case '--clock-offset-seconds':
        offset = int.parse(args[i + 1]);
    }
  }
  if (dir == null) {
    stderr.writeln('--dir missing');
    exit(2);
  }
  final engine = LibreShareEngine(
    self: const DeviceInfo(
      deviceId: 'device-crash-rx',
      alias: 'Crash receiver',
      platform: 'linux',
    ),
    downloadDir: Directory(dir),
    preferredPort: port,
    autoAccept: true,
    bindAddress: InternetAddress.loopbackIPv4,
    enableRateLimit: false,
    clock: _OffsetClock(Duration(seconds: offset)),
  );
  final bound = await engine.start();
  stdout.writeln('READY $bound');
  await stdout.flush();
  await Completer<void>().future; // until killed
}
