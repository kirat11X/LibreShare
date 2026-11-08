// Table-driven pure IP address classifier for Increment 5b (IPv6, CGNAT, private, ULA).

import 'dart:typed_data';

enum IpCategory {
  loopback,
  privateIpv4,
  cgnat,
  linkLocal,
  multicast,
  ula,
  ipv4MappedIpv6,
  globalUnicast,
  reservedOrDoc,
  invalid,
}

final class IpClassification {
  const IpClassification({
    required this.raw,
    required this.category,
    required this.isIpv4,
    required this.isIpv6,
    this.normalized,
  });

  final String raw;
  final IpCategory category;
  final bool isIpv4;
  final bool isIpv6;
  final String? normalized;

  bool get isPublicRoutable => category == IpCategory.globalUnicast;

  bool get isPrivateOrLocal =>
      category == IpCategory.loopback ||
      category == IpCategory.privateIpv4 ||
      category == IpCategory.cgnat ||
      category == IpCategory.linkLocal ||
      category == IpCategory.ula ||
      category == IpCategory.multicast;

  @override
  String toString() =>
      'IpClassification($raw: ${category.name}, public: $isPublicRoutable)';
}

/// Pure table-driven classifier for IPv4 and IPv6 strings.
class IpClassifier {
  IpClassifier._();

  /// Classifies [hostOrIp]. If the input is not a valid IP literal, returns [IpCategory.invalid].
  static IpClassification classify(String hostOrIp) {
    final trimmed = hostOrIp.trim();
    if (trimmed.isEmpty) {
      return IpClassification(
        raw: hostOrIp,
        category: IpCategory.invalid,
        isIpv4: false,
        isIpv6: false,
      );
    }

    // Check IPv4
    final v4Bytes = _parseIpv4(trimmed);
    if (v4Bytes != null) {
      final category = _classifyIpv4(v4Bytes);
      return IpClassification(
        raw: hostOrIp,
        category: category,
        isIpv4: true,
        isIpv6: false,
        normalized: '${v4Bytes[0]}.${v4Bytes[1]}.${v4Bytes[2]}.${v4Bytes[3]}',
      );
    }

    // Check IPv6 (strip optional brackets e.g. [::1])
    var v6Str = trimmed;
    if (v6Str.startsWith('[') && v6Str.endsWith(']')) {
      v6Str = v6Str.substring(1, v6Str.length - 1);
    }

    final v6Bytes = _parseIpv6(v6Str);
    if (v6Bytes != null) {
      final category = _classifyIpv6(v6Bytes);
      return IpClassification(
        raw: hostOrIp,
        category: category,
        isIpv4: false,
        isIpv6: true,
        normalized: _formatIpv6(v6Bytes),
      );
    }

    return IpClassification(
      raw: hostOrIp,
      category: IpCategory.invalid,
      isIpv4: false,
      isIpv6: false,
    );
  }

  static bool isPublicRoutable(String hostOrIp) =>
      classify(hostOrIp).isPublicRoutable;

  static bool isPrivateOrLocal(String hostOrIp) =>
      classify(hostOrIp).isPrivateOrLocal;

  // --- IPv4 Parsing & Classification ---

  static Uint8List? _parseIpv4(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return null;
    final bytes = Uint8List(4);
    for (var i = 0; i < 4; i++) {
      final p = parts[i];
      if (p.isEmpty || (p.length > 1 && p.startsWith('0'))) {
        return null; // no leading zeros
      }
      final val = int.tryParse(p);
      if (val == null || val < 0 || val > 255) return null;
      bytes[i] = val;
    }
    return bytes;
  }

  static IpCategory _classifyIpv4(Uint8List b) {
    final b0 = b[0];
    final b1 = b[1];
    final b2 = b[2];

    // 0.0.0.0/8
    if (b0 == 0) return IpCategory.reservedOrDoc;

    // 127.0.0.0/8
    if (b0 == 127) return IpCategory.loopback;

    // 10.0.0.0/8
    if (b0 == 10) return IpCategory.privateIpv4;

    // 100.64.0.0/10 (CGNAT RFC 6598: 100.64.0.0 to 100.127.255.255)
    if (b0 == 100 && (b1 >= 64 && b1 <= 127)) return IpCategory.cgnat;

    // 169.254.0.0/16
    if (b0 == 169 && b1 == 254) return IpCategory.linkLocal;

    // 172.16.0.0/12
    if (b0 == 172 && (b1 >= 16 && b1 <= 31)) return IpCategory.privateIpv4;

    // 192.0.2.0/24 (TEST-NET-1)
    if (b0 == 192 && b1 == 0 && b2 == 2) return IpCategory.reservedOrDoc;

    // 192.168.0.0/16
    if (b0 == 192 && b1 == 168) return IpCategory.privateIpv4;

    // 198.51.100.0/24 (TEST-NET-2)
    if (b0 == 198 && b1 == 51 && b2 == 100) return IpCategory.reservedOrDoc;

    // 203.0.113.0/24 (TEST-NET-3)
    if (b0 == 203 && b1 == 0 && b2 == 113) return IpCategory.reservedOrDoc;

    // 224.0.0.0/4 (Multicast)
    if (b0 >= 224 && b0 <= 239) return IpCategory.multicast;

    // 240.0.0.0/4 (Reserved / Broadcast)
    if (b0 >= 240) return IpCategory.reservedOrDoc;

    return IpCategory.globalUnicast;
  }

  // --- IPv6 Parsing & Classification ---

  static Uint8List? _parseIpv6(String s) {
    if (s.isEmpty) return null;

    // Handle IPv4-mapped trailing part (e.g., ::ffff:192.0.2.1)
    final lastColon = s.lastIndexOf(':');
    if (lastColon >= 0 && lastColon < s.length - 1) {
      final trailing = s.substring(lastColon + 1);
      if (trailing.contains('.')) {
        final v4 = _parseIpv4(trailing);
        if (v4 == null) return null;
        final v6Prefix = s.substring(0, lastColon);
        final w1 = ((v4[0] << 8) | v4[1]).toRadixString(16);
        final w2 = ((v4[2] << 8) | v4[3]).toRadixString(16);
        final hexPart = '$w1:$w2';
        s = '$v6Prefix:$hexPart';
      }
    }

    final doubleColonCount = '::'.allMatches(s).length;
    if (doubleColonCount > 1) return null;

    final parts = s.split(':');
    if (doubleColonCount == 1) {
      // Expanded zeros
      final otherParts = parts.where((p) => p.isNotEmpty).toList();
      if (otherParts.length > 7) return null;
      final missing = 8 - otherParts.length;

      final expanded = <String>[];
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].isEmpty) {
          // Check if it was double colon at start or end
          if (i == 0 && parts.length > 1 && parts[1].isEmpty) {
            // :: at beginning
            expanded.addAll(List.filled(missing, '0'));
            i++; // skip next empty
          } else if (i == parts.length - 1 &&
              parts.length > 1 &&
              parts[parts.length - 2].isEmpty) {
            // :: at end
            expanded.addAll(List.filled(missing, '0'));
          } else {
            expanded.addAll(List.filled(missing, '0'));
          }
        } else {
          expanded.add(parts[i]);
        }
      }
      if (expanded.length != 8) return null;
      return _wordsToBytes(expanded);
    } else {
      if (parts.length != 8) return null;
      return _wordsToBytes(parts);
    }
  }

  static Uint8List? _wordsToBytes(List<String> words) {
    if (words.length != 8) return null;
    final bytes = Uint8List(16);
    for (var i = 0; i < 8; i++) {
      final w = words[i];
      if (w.isEmpty || w.length > 4) return null;
      final val = int.tryParse(w, radix: 16);
      if (val == null || val < 0 || val > 0xFFFF) return null;
      bytes[i * 2] = (val >> 8) & 0xFF;
      bytes[i * 2 + 1] = val & 0xFF;
    }
    return bytes;
  }

  static IpCategory _classifyIpv6(Uint8List b) {
    // ::1 (Loopback)
    var allZeroExceptLast = true;
    for (var i = 0; i < 15; i++) {
      if (b[i] != 0) {
        allZeroExceptLast = false;
        break;
      }
    }
    if (allZeroExceptLast && b[15] == 1) return IpCategory.loopback;

    // :: (Unspecified)
    if (allZeroExceptLast && b[15] == 0) return IpCategory.reservedOrDoc;

    // ::ffff:0:0/96 (IPv4-mapped)
    var isMapped = true;
    for (var i = 0; i < 10; i++) {
      if (b[i] != 0) {
        isMapped = false;
      }
    }
    if (isMapped && b[10] == 0xFF && b[11] == 0xFF) {
      return IpCategory.ipv4MappedIpv6;
    }

    // fe80::/10 (Link-Local: 1111 1110 10xx xxxx -> 0xFE80..0xFEBF)
    if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return IpCategory.linkLocal;

    // fc00::/7 (ULA: 1111 110x xxxx xxxx -> 0xFC00..0xFDFF)
    if ((b[0] & 0xFE) == 0xFC) return IpCategory.ula;

    // ff00::/8 (Multicast)
    if (b[0] == 0xFF) return IpCategory.multicast;

    // 2001:db8::/32 (Documentation RFC 3849)
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8) {
      return IpCategory.reservedOrDoc;
    }

    // 2000::/3 (Global Unicast: 001x xxxx -> 0x2000..0x3FFF)
    if ((b[0] & 0xE0) == 0x20) return IpCategory.globalUnicast;

    return IpCategory.reservedOrDoc;
  }

  static String _formatIpv6(Uint8List b) {
    final words = <int>[];
    for (var i = 0; i < 8; i++) {
      words.add((b[i * 2] << 8) | b[i * 2 + 1]);
    }
    return words.map((w) => w.toRadixString(16)).join(':');
  }
}
