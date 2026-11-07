import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
void main() {
  for (final n in ['.. ', '...', '. ', '..', 'a.', 'a ', r'a:b', r'f.txt:s', 'CON', r'..\x', '.. /x', 'x/.. ', '\u202e..']) {
    String r;
    try { r = '"${sanitizeFileName(n)}"'; } catch (e) { r = 'THROWS'; }
    String d;
    try { d = sanitizeRelativePath(n).toString(); } catch (e) { d = 'THROWS'; }
    print('name=${n.replaceAll("\u202e","<RLO>")}  file->$r  relpath->$d');
  }
  for (final c in [r'C:\a\.. \x', r'C:\a\...\x', r'C:\a\. \x', r'C:\a\..\x', r'C:\a\.\x', r'C:\a\.. ', r'C:\a\..  \..\x']) {
    print('$c within=${isPathWithin(r'C:\a', c, windows: true)}');
  }
}
