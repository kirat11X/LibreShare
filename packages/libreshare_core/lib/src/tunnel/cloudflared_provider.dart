import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'binary_installer.dart';
import 'cloudflared_versions.dart';
import 'process_supervisor.dart';
import 'tunnel_provider.dart';

class CloudflaredProvider implements TunnelProvider {
  final Directory appSupportDirectory;
  final String? customBinaryPath;

  CloudflaredProvider({
    required this.appSupportDirectory,
    this.customBinaryPath,
  });

  @override
  String get id => 'cloudflare-quick';

  File get _pidFile => File('${appSupportDirectory.path}/run/tunnel.pid');

  File get binaryFile {
    if (customBinaryPath != null) {
      return File(customBinaryPath!);
    }
    final installer = BinaryInstaller(
      binDirectory: Directory('${appSupportDirectory.path}/bin'),
    );
    final ext = Platform.isWindows ? '.exe' : '';
    return installer.fileFor('cloudflared-$kCloudflaredVersion$ext');
  }

  @override
  Future<bool> isAvailable() async {
    return binaryFile.exists();
  }

  @override
  Future<TunnelHandle> open(
    int localPort, {
    Duration ready = const Duration(seconds: 45),
  }) async {
    await ProcessSupervisor.cleanStalePidfile(_pidFile);

    final emptyConfig = File(
      '${appSupportDirectory.path}/tmp/empty_config.yml',
    );
    if (!await emptyConfig.parent.exists()) {
      await emptyConfig.parent.create(recursive: true);
    }
    await emptyConfig.writeAsString('', flush: true);

    final argv = ProcessSupervisor.buildCloudflaredArgv(
      localPort: localPort,
      tempConfigPath: emptyConfig.path,
    );

    // Launch process with scrubbed clean HOME / USERPROFILE environment
    final cleanEnv = Map<String, String>.from(Platform.environment);
    final tempHome = Directory(
      '${appSupportDirectory.path}/tmp/home_${DateTime.now().microsecondsSinceEpoch}',
    );
    await tempHome.create(recursive: true);
    cleanEnv['HOME'] = tempHome.path;
    cleanEnv['USERPROFILE'] = tempHome.path;

    final process = await Process.start(
      binaryFile.path,
      argv,
      environment: cleanEnv,
    );

    await ProcessSupervisor.writePidfile(_pidFile, process.pid);

    final urlCompleter = Completer<Uri>();
    final eventController = StreamController<TunnelEvent>.broadcast();

    // Monitor stderr for URL discovery and errors
    final buffer = StringBuffer();
    process.stderr.transform(utf8.decoder).listen((line) {
      buffer.write(line);
      final url = ProcessSupervisor.extractTunnelUrl(buffer.toString());
      if (url != null && !urlCompleter.isCompleted) {
        urlCompleter.complete(url);
        eventController.add(const TunnelUpEvent());
      }
      if (line.contains('429') || line.contains('1015')) {
        eventController.add(
          const TunnelRateLimitedEvent(Duration(seconds: 10)),
        );
      }
    });

    // Handle exit
    unawaited(
      process.exitCode.then((code) {
        if (!urlCompleter.isCompleted) {
          urlCompleter.completeError(
            TunnelLostEvent(
              'cloudflared exited before ready with code $code: ${buffer.toString()}',
            ),
          );
        }
        eventController.add(TunnelLostEvent('exited with code $code'));
      }),
    );

    final publicBase = await urlCompleter.future.timeout(
      ready,
      onTimeout: () {
        process.kill();
        throw TimeoutException(
          'cloudflared tunnel failed to establish within $ready',
        );
      },
    );

    return _CloudflaredHandle(
      publicBase: publicBase,
      process: process,
      pidFile: _pidFile,
      eventController: eventController,
      tempHome: tempHome,
    );
  }
}

class _CloudflaredHandle implements TunnelHandle {
  @override
  final Uri publicBase;
  final Process process;
  final File pidFile;
  final StreamController<TunnelEvent> eventController;
  final Directory tempHome;

  _CloudflaredHandle({
    required this.publicBase,
    required this.process,
    required this.pidFile,
    required this.eventController,
    required this.tempHome,
  });

  @override
  Stream<TunnelEvent> get events => eventController.stream;

  @override
  Future<void> close() async {
    process.kill(ProcessSignal.sigterm);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    try {
      process.kill(ProcessSignal.sigkill);
    } catch (_) {}
    await ProcessSupervisor.cleanStalePidfile(pidFile);
    await eventController.close();
    try {
      if (await tempHome.exists()) {
        await tempHome.delete(recursive: true);
      }
    } catch (_) {}
  }
}
