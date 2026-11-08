// Proof for mutant M14: assertInsideDir rejects any path containing a ".." segment, even one that stays inside.
import 'dart:io';

import 'package:libreshare_core/src/model/ls_exception.dart';
import 'package:libreshare_core/src/transfer/filename_sanitizer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'dot-dot segment rejected even when it normalises to an inside path',
    () {
      final root = Directory.systemTemp.createTempSync('ls_m14_');
      addTearDown(() => root.deleteSync(recursive: true));
      assertInsideDir(
        root,
        p.join(root.path, 'a', 'b.txt'),
      ); // positive control
      expect(
        () => assertInsideDir(root, '${root.path}/a/../b.txt'),
        throwsA(isA<LsException>()),
      );
    },
  );
}
