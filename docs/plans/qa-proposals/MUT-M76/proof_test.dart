// Proof for mutant M76: IPv6 link-local is the whole fe80::/10 range (fe80..febf).
import 'package:libreshare_core/src/nat/ip_classify.dart';
import 'package:test/test.dart';

void main() {
  for (final a in ['fe80::1', 'fe81::1', 'fea0::1', 'febf::1']) {
    test('$a is link-local, not public', () {
      final c = IpClassifier.classify(a);
      expect(c.category, IpCategory.linkLocal);
      expect(c.isPublicRoutable, isFalse);
    });
  }
  test('fec0::1 (outside /10) is not link-local', () {
    expect(
      IpClassifier.classify('fec0::1').category,
      isNot(IpCategory.linkLocal),
    );
  });
}
