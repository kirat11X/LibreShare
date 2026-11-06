/// QR / manual pairing (spec §4.2 rule 6, screen 8): the
/// `libreshare://peer?ip=<ip>&port=53318&fp=<64hex>&id=<uuid>&n=<alias>` link,
/// and resolving a manually entered address by asking the peer for `/info`.
///
/// A scanned QR code is attacker-controlled input, so [PeerLink.parse] is
/// strict and never echoes the input in its errors:
/// * total length ≤ 512; ASCII only (everything else must be percent-encoded)
///   and only RFC 3986 query characters;
/// * scheme `libreshare` and host `peer` (case-insensitive per RFC 3986), no
///   userinfo, authority port, path (one trailing `/` tolerated) or fragment;
/// * `ip` is a literal IPv4 or IPv6 address (no hostnames, zones, leading
///   zeros, brackets) that is a plausible unicast peer (not `0.0.0.0/8`,
///   multicast or reserved/broadcast, `::`, `ff00::/8`);
/// * `port` is 1..65535 in plain decimal (default 53318 when absent);
/// * `fp` is exactly 64 hex digits (normalised to upper case) or absent;
/// * `id` is a UUID (normalised to lower case) or absent;
/// * `n` is 1..64 characters (code points) without control, line-separator,
///   bidi-override or BOM characters;
/// * known parameters must not repeat; unknown parameters are ignored
///   (not even decoded); keys are matched case-sensitively and un-decoded.
/// Percent-decoding is RFC 3986 (`+` is a plus, not a space) and happens once.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model/device.dart';
import '../protocol.dart';
import 'subnet_scanner.dart' show InfoProbe, defaultInfoProbe;

/// Longest accepted/produced link, in characters.
const int kPeerLinkMaxLength = 512;

/// Longest alias in a link, in Unicode code points.
const int kPeerLinkMaxAliasLength = 64;

const String _linkPrefix = 'libreshare://peer';

final RegExp _queryChars = RegExp(r"^[A-Za-z0-9\-._~!$&'()*+,;=:@/?%]*$");
final RegExp _portRe = RegExp(r'^[1-9][0-9]{0,4}$');
final RegExp _hex64Re = RegExp(r'^[0-9a-fA-F]{64}$');
final RegExp _uuidRe = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

FormatException _bad(String what) =>
    FormatException('Invalid peer link: $what');

// ------------------------------------------------------------ fingerprints

/// Upper-case form of a 64-hex SHA-256 fingerprint, or null if [fp] is not
/// exactly 64 hex digits (e.g. the empty pre-TLS fingerprint).
String? normalizeFingerprint(String fp) =>
    _hex64Re.hasMatch(fp) ? fp.toUpperCase() : null;

String _hexOnly(String fp) =>
    fp.replaceAll(RegExp(r'[\s:\-]'), '').toUpperCase();

/// `AB12 CD34 …`: upper case in groups of four, for the confirmation dialog.
String displayFingerprint(String fp) {
  final h = _hexOnly(fp);
  final b = StringBuffer();
  for (var i = 0; i < h.length; i += 4) {
    if (i > 0) b.write(' ');
    b.write(h.substring(i, i + 4 > h.length ? h.length : i + 4));
  }
  return b.toString();
}

/// First 16 hex digits, upper case (mDNS `fp`, tunnel links, spec §4.2).
String shortFingerprint(String fp) {
  final h = _hexOnly(fp);
  return h.length <= 16 ? h : h.substring(0, 16);
}

// ---------------------------------------------------------------- PeerLink

class PeerLink {
  /// Builds a link, applying the same validation and normalisation as
  /// [PeerLink.parse]; throws [FormatException] for anything invalid,
  /// including an alias that would make the encoded link exceed
  /// [kPeerLinkMaxLength] characters.
  factory PeerLink({
    required String ip,
    int port = kDefaultPort,
    String? fingerprint,
    String? deviceId,
    String? alias,
  }) {
    final link = PeerLink._checked(
      ip: ip,
      port: port,
      fingerprint: fingerprint,
      deviceId: deviceId,
      alias: alias,
    );
    if (link.toUri().length > kPeerLinkMaxLength) {
      throw _bad('link longer than $kPeerLinkMaxLength characters');
    }
    return link;
  }

  PeerLink._checked({
    required String ip,
    required int port,
    String? fingerprint,
    String? deviceId,
    String? alias,
  }) : ip = _checkIp(ip),
       port = _checkPort(port),
       fingerprint = fingerprint == null
           ? null
           : _checkFingerprint(fingerprint),
       deviceId = deviceId == null ? null : _checkUuid(deviceId),
       alias = alias == null ? null : _checkAlias(alias);

  /// Parses and validates [input] (see the library docs). Throws
  /// [FormatException] with a fixed, input-free message.
  factory PeerLink.parse(String input) {
    final s = input.trim();
    if (s.isEmpty) throw _bad('empty');
    if (s.length > kPeerLinkMaxLength) {
      throw _bad('longer than $kPeerLinkMaxLength characters');
    }
    for (final c in s.codeUnits) {
      if (c <= 0x20 || c >= 0x7f) throw _bad('illegal character');
    }
    if (s.length < _linkPrefix.length ||
        s.substring(0, _linkPrefix.length).toLowerCase() != _linkPrefix) {
      throw _bad('not a libreshare://peer link');
    }
    var rest = s.substring(_linkPrefix.length);
    if (rest.startsWith('/')) rest = rest.substring(1);
    if (!rest.startsWith('?')) {
      throw _bad('unexpected user, port or path after the host');
    }
    final query = rest.substring(1);
    if (!_queryChars.hasMatch(query)) throw _bad('illegal character in query');

    final params = <String, String>{};
    for (final segment in query.split('&')) {
      if (segment.isEmpty) continue;
      final eq = segment.indexOf('=');
      final key = eq < 0 ? segment : segment.substring(0, eq);
      if (!_knownKeys.contains(key)) continue; // ignored, not even decoded
      if (params.containsKey(key)) throw _bad('repeated parameter');
      params[key] = _decode(eq < 0 ? '' : segment.substring(eq + 1));
    }

    final ip = params['ip'];
    if (ip == null) throw _bad('missing ip');
    final port = params['port'];
    return PeerLink._checked(
      ip: ip,
      port: port == null ? kDefaultPort : _parsePort(port),
      fingerprint: params['fp'],
      deviceId: params['id'],
      alias: params['n'],
    );
  }

  /// [PeerLink.parse] returning null instead of throwing.
  static PeerLink? tryParse(String input) {
    try {
      return PeerLink.parse(input);
    } on FormatException {
      return null;
    }
  }

  /// The link another device would scan to reach [info] at [ip] ("My QR").
  /// Adapts instead of throwing: an empty/invalid fingerprint (no TLS yet) or
  /// a non-UUID device id is left out, forbidden characters are stripped from
  /// the alias, which is truncated to fit 64 characters and the 512-char cap.
  factory PeerLink.fromDevice(DeviceInfo info, String ip) {
    final fp = normalizeFingerprint(info.fingerprint);
    final id = _uuidRe.hasMatch(info.deviceId) ? info.deviceId : null;
    final cleaned = String.fromCharCodes(
      info.alias.runes.where((c) => !_forbiddenInAlias(c)),
    ).trim();
    final chars = cleaned.runes.take(kPeerLinkMaxAliasLength).toList();
    while (true) {
      final text = String.fromCharCodes(chars);
      final link = PeerLink._checked(
        ip: ip,
        port: info.port,
        fingerprint: fp,
        deviceId: id,
        alias: text.isEmpty ? null : text,
      );
      if (link.toUri().length <= kPeerLinkMaxLength) return link;
      if (chars.isEmpty) throw _bad('link longer than $kPeerLinkMaxLength');
      chars.removeLast();
    }
  }

  /// Validated IPv4 or (normalised) IPv6 literal.
  final String ip;
  final int port;

  /// Upper-case 64-hex certificate fingerprint, if the link carries one.
  final String? fingerprint;

  /// Lower-case UUID of the peer, if the link carries one.
  final String? deviceId;
  final String? alias;

  /// `libreshare://peer?ip=…&port=…[&fp=…][&id=…][&n=…]`, every value
  /// RFC 3986 percent-encoded (UTF-8, upper-case hex, only unreserved
  /// characters left as they are).
  String toUri() {
    final b = StringBuffer('$_linkPrefix?ip=${_encode(ip)}&port=$port');
    if (fingerprint != null) b.write('&fp=$fingerprint');
    if (deviceId != null) b.write('&id=$deviceId');
    if (alias != null) b.write('&n=${_encode(alias!)}');
    return b.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is PeerLink &&
      other.ip == ip &&
      other.port == port &&
      other.fingerprint == fingerprint &&
      other.deviceId == deviceId &&
      other.alias == alias;

  @override
  int get hashCode => Object.hash(ip, port, fingerprint, deviceId, alias);

  @override
  String toString() => 'PeerLink(${toUri()})';

  // ------------------------------------------------------------ validation

  static const Set<String> _knownKeys = {'ip', 'port', 'fp', 'id', 'n'};

  static String _decode(String raw) {
    try {
      return Uri.decodeComponent(raw);
    } on FormatException {
      throw _bad('bad percent-encoding');
    } on ArgumentError {
      throw _bad('bad percent-encoding');
    }
  }

  static int _parsePort(String s) {
    if (!_portRe.hasMatch(s)) throw _bad('port');
    return _checkPort(int.parse(s));
  }

  static int _checkPort(int port) {
    if (port < 1 || port > 65535) throw _bad('port out of range');
    return port;
  }

  static String _checkIp(String ip) {
    final a = InternetAddress.tryParse(ip);
    if (a == null) throw _bad('ip is not an IPv4 or IPv6 literal');
    if (a.type == InternetAddressType.IPv4 && a.address != ip) {
      throw _bad('ip is not in canonical dotted-quad form');
    }
    if (!_isUsablePeerAddress(a.rawAddress)) {
      throw _bad('ip is not a usable unicast address');
    }
    return a.address;
  }

  /// Rejects 0.0.0.0/8, multicast and reserved/broadcast (224.0.0.0+), `::`,
  /// ff00::/8, and IPv4-mapped IPv6 forms of the same.
  static bool _isUsablePeerAddress(List<int> raw) {
    if (raw.length == 4) return raw[0] != 0 && raw[0] < 224;
    if (raw.length != 16) return false;
    if (raw.every((b) => b == 0)) return false;
    if (raw[0] == 0xff) return false;
    final mapped =
        raw.take(10).every((b) => b == 0) && raw[10] == 0xff && raw[11] == 0xff;
    return !mapped || _isUsablePeerAddress(raw.sublist(12));
  }

  static String _checkFingerprint(String fp) {
    final n = normalizeFingerprint(fp);
    if (n == null) throw _bad('fp must be 64 hex digits');
    return n;
  }

  static String _checkUuid(String id) {
    if (!_uuidRe.hasMatch(id)) throw _bad('id must be a UUID');
    return id.toLowerCase();
  }

  static String _checkAlias(String alias) {
    var count = 0;
    for (final c in alias.runes) {
      if (_forbiddenInAlias(c)) throw _bad('forbidden character in n');
      count++;
    }
    if (count == 0) throw _bad('n is empty');
    if (count > kPeerLinkMaxAliasLength) {
      throw _bad('n longer than $kPeerLinkMaxAliasLength characters');
    }
    return alias;
  }

  /// C0/C1 controls, DEL, line/paragraph separators, bidi marks/embeddings/
  /// overrides/isolates (alias spoofing), BOM, and unpaired surrogates.
  static bool _forbiddenInAlias(int c) =>
      c < 0x20 ||
      (c >= 0x7f && c <= 0x9f) ||
      c == 0x061c ||
      c == 0x200e ||
      c == 0x200f ||
      c == 0x2028 ||
      c == 0x2029 ||
      (c >= 0x202a && c <= 0x202e) ||
      (c >= 0x2066 && c <= 0x2069) ||
      c == 0xfeff ||
      (c >= 0xd800 && c <= 0xdfff);

  static String _encode(String s) {
    final b = StringBuffer();
    for (final byte in utf8.encode(s)) {
      final unreserved =
          (byte >= 0x30 && byte <= 0x39) ||
          (byte >= 0x41 && byte <= 0x5a) ||
          (byte >= 0x61 && byte <= 0x7a) ||
          byte == 0x2d ||
          byte == 0x2e ||
          byte == 0x5f ||
          byte == 0x7e;
      if (unreserved) {
        b.writeCharCode(byte);
      } else {
        b
          ..write('%')
          ..write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return b.toString();
  }
}

// ---------------------------------------------------------------- resolver

/// Why a manually entered / scanned peer was not accepted. All are safe to
/// show to the user.
sealed class PeerResolveException implements Exception {
  const PeerResolveException();
  String get message;
  @override
  String toString() => '$runtimeType: $message';
}

/// `GET /info` got no valid answer (refused, timeout, not a LibreShare peer).
final class PeerUnreachable extends PeerResolveException {
  const PeerUnreachable(this.address, this.port);
  final String address;
  final int port;
  @override
  String get message => 'No LibreShare device answered at this address';
}

/// The QR code pinned a fingerprint and the device at the address presents a
/// different one (or none): wrong device, or someone in the middle.
final class FingerprintMismatch extends PeerResolveException {
  const FingerprintMismatch({required this.expected, required this.actual});

  /// Upper-case fingerprint from the link.
  final String expected;

  /// Upper-case fingerprint the device presented; empty if it presented none.
  final String actual;
  @override
  String get message => 'The device does not match the fingerprint in the QR';
}

/// The QR code names a device id and the device at the address has another.
final class DeviceIdMismatch extends PeerResolveException {
  const DeviceIdMismatch({required this.expected, required this.actual});
  final String expected;
  final String actual;
  @override
  String get message => 'A different device answered at this address';
}

class ResolvedPeer {
  const ResolvedPeer({
    required this.info,
    required this.address,
    required this.port,
    this.fingerprintToConfirm,
    this.fingerprintVerified = false,
  });

  /// What the peer reported about itself.
  final DeviceInfo info;

  /// The IP that answered (feed to `PeerSink.seen(info, address, manual/qr)`).
  final String address;

  /// The port that answered.
  final int port;

  /// Upper-case fingerprint the UI must show for the user to confirm
  /// (manual entry). Null when a QR already verified it, or when the peer
  /// has no fingerprint yet (before TLS, Increment 3).
  final String? fingerprintToConfirm;

  /// A QR-supplied fingerprint matched the peer's.
  final bool fingerprintVerified;
}

class ManualPeerResolver {
  ManualPeerResolver({InfoProbe? probe}) : _probe = probe ?? defaultInfoProbe;

  /// Connect/request budget used when none is given (spec §6: 3 s).
  static const Duration defaultTimeout = Duration(seconds: 3);

  final InfoProbe _probe;

  /// Asks the device at [ip]:[port] who it is.
  ///
  /// With [expectedFingerprint] / [expectedDeviceId] (from a scanned link) the
  /// answer must match: otherwise [FingerprintMismatch] / [DeviceIdMismatch]
  /// (a peer that presents no fingerprint cannot satisfy an expected one).
  /// Without them (manual entry) the peer's own fingerprint is returned as
  /// [ResolvedPeer.fingerprintToConfirm] for the user to compare out of band.
  ///
  /// Throws [FormatException] for an invalid [ip]/[port]/expected value and
  /// [PeerUnreachable] when nobody (valid) answers within [timeout].
  Future<ResolvedPeer> resolve(
    String ip,
    int port, {
    Duration timeout = defaultTimeout,
    String? expectedFingerprint,
    String? expectedDeviceId,
  }) async {
    final link = PeerLink(
      ip: ip,
      port: port,
      fingerprint: expectedFingerprint,
      deviceId: expectedDeviceId,
    );
    return resolveLink(link, timeout: timeout);
  }

  /// [resolve] with everything taken from a parsed [link].
  Future<ResolvedPeer> resolveLink(
    PeerLink link, {
    Duration timeout = defaultTimeout,
  }) async {
    DeviceInfo? info;
    try {
      info = await _probe(
        link.ip,
        link.port,
        timeout,
      ).timeout(timeout + const Duration(milliseconds: 100));
    } on Object {
      info = null;
    }
    if (info == null) throw PeerUnreachable(link.ip, link.port);

    final actualFp = normalizeFingerprint(info.fingerprint);
    final expectedFp = link.fingerprint;
    if (expectedFp != null && actualFp != expectedFp) {
      throw FingerprintMismatch(expected: expectedFp, actual: actualFp ?? '');
    }
    final expectedId = link.deviceId;
    if (expectedId != null && info.deviceId.toLowerCase() != expectedId) {
      throw DeviceIdMismatch(expected: expectedId, actual: info.deviceId);
    }
    return ResolvedPeer(
      info: info,
      address: link.ip,
      port: link.port,
      fingerprintToConfirm: expectedFp == null ? actualFp : null,
      fingerprintVerified: expectedFp != null,
    );
  }
}
