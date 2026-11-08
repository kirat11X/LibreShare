import 'dart:async';
import 'dart:io';

class ProcessSupervisor {
  static final RegExp _tryCloudflareRegex = RegExp(
    r'https://[a-zA-Z0-9-]+\.trycloudflare\.com',
  );

  static Uri? extractTunnelUrl(String output) {
    final match = _tryCloudflareRegex.firstMatch(output);
    if (match != null) {
      return Uri.tryParse(match.group(0)!);
    }
    return null;
  }

  static List<String> buildCloudflaredArgv({
    required int localPort,
    String? tempConfigPath,
  }) {
    final argv = <String>[
      'tunnel',
      '--url',
      'http://127.0.0.1:$localPort',
      '--no-autoupdate',
      '--loglevel',
      'info',
    ];
    if (tempConfigPath != null) {
      argv.addAll(['--config', tempConfigPath]);
    }
    // Hard invariant: never pass --allowed-mail
    assert(!argv.contains('--allowed-mail'));
    return argv;
  }

  static Future<void> cleanStalePidfile(File pidFile) async {
    if (!await pidFile.exists()) return;
    try {
      final content = await pidFile.readAsString();
      final pid = int.tryParse(content.trim());
      if (pid != null && pid > 0) {
        // Attempt clean termination of stale process if it exists
        try {
          Process.killPid(pid, ProcessSignal.sigterm);
        } catch (_) {}
      }
      await pidFile.delete();
    } catch (_) {}
  }

  static Future<void> writePidfile(File pidFile, int pid) async {
    try {
      if (!await pidFile.parent.exists()) {
        await pidFile.parent.create(recursive: true);
      }
      await pidFile.writeAsString('$pid\n', flush: true);
    } catch (_) {}
  }
}
