enum OriginKind { tunnel, ipv6, ipv4Mapped, manual }

final class OriginCandidate {
  final OriginKind kind;
  final Uri base;
  final String? tlsPinHex;

  const OriginCandidate({
    required this.kind,
    required this.base,
    this.tlsPinHex,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OriginCandidate &&
          runtimeType == other.runtimeType &&
          kind == other.kind &&
          base == other.base &&
          tlsPinHex == other.tlsPinHex;

  @override
  int get hashCode => Object.hash(kind, base, tlsPinHex);

  @override
  String toString() =>
      'OriginCandidate(kind: $kind, base: $base, tlsPinHex: ${tlsPinHex != null ? "[pinned]" : "null"})';
}
