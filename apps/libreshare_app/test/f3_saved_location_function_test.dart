// F3 defect 3 (b), pure function. New symbol in services/paths.dart:
//   String describeSavedLocation(String folderPath)
// "Downloads/<folder>" for folders under the public shared-storage roots
// (/storage/emulated/<user>/, /storage/self/primary/, /sdcard/) whose FIRST
// segment is Download, Documents, Pictures, DCIM, Music or Movies (Download is
// shown as "Downloads"); the real path, unchanged, for everything else.
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/services/paths.dart';

void main() {
  const friendly = <String, String>{
    '/storage/emulated/0/Download/LibreShare': 'Downloads/LibreShare',
    '/storage/emulated/0/Download': 'Downloads',
    '/storage/emulated/0/Download/': 'Downloads',
    '/storage/emulated/0/Download/LibreShare/': 'Downloads/LibreShare',
    '/storage/emulated/0/Download/Trips/2026': 'Downloads/Trips/2026',
    '/storage/emulated/0/Documents/Work/Reports': 'Documents/Work/Reports',
    '/storage/emulated/0/Pictures/LibreShare': 'Pictures/LibreShare',
    '/storage/emulated/0/DCIM/Camera': 'DCIM/Camera',
    '/storage/emulated/0/Music/Mix': 'Music/Mix',
    '/storage/emulated/0/Movies/Clips': 'Movies/Clips',
    '/sdcard/Download/LibreShare': 'Downloads/LibreShare',
    '/storage/self/primary/Download/LibreShare': 'Downloads/LibreShare',
    '/storage/emulated/10/Download/x': 'Downloads/x',
  };
  for (final e in friendly.entries) {
    test('${e.key} reads "${e.value}"', () {
      expect(describeSavedLocation(e.key), e.value);
    });
  }

  const real = <String>[
    // The app-private default: "Download" is not the first segment.
    '/storage/emulated/0/Android/data/dev.libreshare.libreshare_app/files/Download/LibreShare',
    '/storage/emulated/0/Other/Download/x',
    '/storage/emulated/0/Downloads/x', // not the system folder name
    '/storage/emulated/0/Downloadable',
    '/storage/emulated/0/DocumentsOld/x',
    '/data/user/0/dev.libreshare.libreshare_app/files',
    '/home/me/Downloads/LibreShare',
    '/home/me/Download/LibreShare',
    r'C:\Users\me\Downloads\LibreShare',
    '/mnt/sdcard/Download/x',
    '/sdcardx/Download/x',
  ];
  for (final p in real) {
    test('$p stays as it is', () {
      expect(describeSavedLocation(p), p);
    });
  }

  test('an empty path does not crash', () {
    expect(describeSavedLocation(''), '');
  });
}
