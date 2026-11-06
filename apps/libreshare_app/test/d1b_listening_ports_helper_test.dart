// Test isolation of the `listeningPorts` helper (d1b_helpers.dart): it must
// see the sockets of THIS process only, because `flutter test --concurrency=2`
// runs other test processes that listen on the same loopback alias (every app
// test binds 127.0.0.2).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/d1b_helpers.dart';

const String _childScript = '''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final server = await ServerSocket.bind(InternetAddress(args[0]), 0);
  stdout.writeln(server.port);
  await stdout.flush();
  await stdin.transform(const SystemEncoding().decoder).first.catchError((_) => '');
  await server.close();
}
''';

/// A real `dart` binary. Under `flutter test` Platform.resolvedExecutable is
/// flutter_tester (it does not run arbitrary scripts), so walk up to the
/// Flutter SDK's bundled Dart; fall back to `dart` on the PATH.
String dartExecutable() {
  final exe = Platform.resolvedExecutable;
  if (exe.split(Platform.pathSeparator).last == 'dart') return exe;
  var dir = File(exe).parent;
  for (var i = 0; i < 8; i++) {
    final cand = File(
      [dir.path, 'dart-sdk', 'bin', 'dart'].join(Platform.pathSeparator),
    );
    if (cand.existsSync()) return cand.path;
    final cand2 = File(
      [
        dir.path,
        'cache',
        'dart-sdk',
        'bin',
        'dart',
      ].join(Platform.pathSeparator),
    );
    if (cand2.existsSync()) return cand2.path;
    dir = dir.parent;
  }
  return 'dart';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ip = '127.0.0.2';

  test(
    'positive twin: a socket bound by this process is in the set',
    () async {
      final server = await ServerSocket.bind(InternetAddress(ip), 0);
      addTearDown(server.close);
      expect(listeningPorts(ip), contains(server.port));
      await server.close();
      expect(
        listeningPorts(ip),
        isNot(contains(server.port)),
        reason: 'a closed socket is gone from the set',
      );
    },
    skip: kHasProcNet ? false : 'needs /proc/net/tcp',
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'negative twin: a socket bound by ANOTHER process is not in the set',
    () async {
      final dir = Directory.systemTemp.createTempSync('ls_ports_helper_');
      final script = File('${dir.path}${Platform.pathSeparator}child.dart')
        ..writeAsStringSync(_childScript);
      final child = await Process.start(dartExecutable(), [script.path, ip]);
      addTearDown(() async {
        child.kill();
        await child.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () => -1,
        );
        script.deleteSync();
        dir.deleteSync();
      });
      final line = await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((l) => int.tryParse(l.trim()) != null)
          .timeout(const Duration(seconds: 45));
      final childPort = int.parse(line.trim());

      // The OS really lists the child's socket (so the test can fail)...
      final table = File('/proc/net/tcp').readAsStringSync().toUpperCase();
      final hexPort = childPort.toRadixString(16).toUpperCase().padLeft(4, '0');
      expect(
        table.contains('0200007F:$hexPort'),
        isTrue,
        reason: 'the child listens on $ip:$childPort in the machine-wide table',
      );
      // ...but it is not ours.
      expect(
        listeningPorts(ip),
        isNot(contains(childPort)),
        reason: 'only sockets owned by this process may be reported',
      );

      // And our own socket is still reported next to it.
      final mine = await ServerSocket.bind(InternetAddress(ip), 0);
      addTearDown(mine.close);
      expect(listeningPorts(ip), contains(mine.port));
      expect(listeningPorts(ip), isNot(contains(childPort)));
    },
    skip: kHasProcNet ? false : 'needs /proc/net/tcp',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
