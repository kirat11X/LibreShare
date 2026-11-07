import 'package:path/path.dart' as p;
void main() {
  for (final c in [['/', ' a/'], ['..', 'ab'], ['/ab//..', ' a'], ['/', 'a'], ['/', '/a'], ['a','a/b'], ['..','../x']]) {
    print('$c  p.isWithin=${p.isWithin(c[0], c[1])} posix=${p.posix.isWithin(c[0], c[1])} p.current=${p.current} posix.current=${p.posix.current} style=${p.style.name}');
  }
}
