import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tunnel_provider.dart';

class ZrokProvider implements TunnelProvider {
  final String accountToken;
  final String zrokBinaryPath;

  ZrokProvider({required this.accountToken, this.zrokBinaryPath = 'zrok2'});

  @override
  String get id => 'zrok';

  @override
  Future<bool> isAvailable() async {
    return accountToken.isNotEmpty;
  }

  @override
  Future<TunnelHandle> open(
    int localPort, {
    Duration ready = const Duration(seconds: 45),
  }) async {
    final process = await Process.start(
      zrokBinaryPath,
      ['share', 'public', 'http://127.0.0.1:$localPort', '--headless'],
      environment: {'ZROK_TOKEN': accountToken},
    );

    final urlCompleter = Completer<Uri>();
    final eventController = StreamController<TunnelEvent>.broadcast();

    process.stdout.transform(utf8.decoder).listen((line) {
      final match = RegExp(r'https://[a-zA-Z0-9-]+\.share\.zrok\.io')
          .firstMatch(line);
      if (match != null && !urlCompleter.isCompleted) {
        urlCompleter.complete(Uri.parse(match.group(0)!));
        eventController.add(const TunnelUpEvent());
      }
    });

    final publicBase = await urlCompleter.future.timeout(
      ready,
      onTimeout: () {
        process.kill();
        throw TimeoutException('zrok share failed to establish within $ready');
      },
    );

    return _ZrokHandle(
      publicBase: publicBase,
      process: process,
      eventController: eventController,
    );
  }
}

class _ZrokHandle implements TunnelHandle {
  @override
  final Uri publicBase;
  final Process process;
  final StreamController<TunnelEvent> eventController;

  _ZrokHandle({
    required this.publicBase,
    required this.process,
    required this.eventController,
  });

  @override
  Stream<TunnelEvent> get events => eventController.stream;

  @override
  Future<void> close() async {
    process.kill(ProcessSignal.sigterm);
    await eventController.close();
  }
}
