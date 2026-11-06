import 'dart:io';

import 'package:libreshare_cli/ls_cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
