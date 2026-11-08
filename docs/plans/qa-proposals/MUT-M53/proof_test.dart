// Proof for mutant M53: tunnel seal nonce must be random per seal (never constant).
import 'package:libreshare_core/src/security/tunnel_crypto.dart';
import 'package:test/test.dart';

void main() {
  test('two seals of the same plaintext use different nonces', () {
    final keys = TunnelKeys.fromRootKey(List<int>.filled(32, 7));
    final a = keys.seal(TunnelPurpose.manifest, [1, 2, 3]);
    final b = keys.seal(TunnelPurpose.manifest, [1, 2, 3]);
    expect(a.sublist(0, kTunnelNonceBytes), isNot(b.sublist(0, kTunnelNonceBytes)));
    expect(a, isNot(b));
  });
}
