/// Discovery datagram codec (spec §4.2, LSP-1 §4.2): a `DeviceInfo` plus
/// `announce` as UTF-8 JSON of at most [kMaxAnnounceBytes] bytes.
///
/// [decodeAnnounce] is the trust boundary for unauthenticated UDP input: it
/// NEVER throws and returns `null` for anything that is not a well-formed LSP/1
/// announcement. [encodeAnnounce] never truncates JSON; when the address list
/// would overflow the datagram it drops addresses from the tail instead.
library;

import 'dart:convert';
import 'dart:io' show InternetAddress;
import 'dart:typed_data';

import '../model/device.dart';
import '../protocol.dart';
import '../security/contracts.dart';
import '../security/crypto_primitives.dart' show b64urlDecode, b64urlEncode;

/// Hard datagram limit (LSP-1 §4.2).
const int kMaxAnnounceBytes = 1200;

/// Longest accepted alias, in Unicode code points.
const int kMaxAnnounceAliasLength = 64;

/// Most addresses accepted in (and emitted into) one announcement.
const int kMaxAnnounceAddrs = 8;

const int _maxIdLength = 128;
const int _maxTagLength = 32; // platform, deviceType, caps entries, iface
const int _maxCaps = 16;
const Set<String> _ifaceClasses = {'wifi', 'ethernet', 'unknown'};

/// A decoded discovery datagram.
class AnnounceMessage {
  const AnnounceMessage(this.info, {required this.announce});

  /// The announcing device. `info.fingerprint` is normalised to uppercase.
  final DeviceInfo info;

  /// `true`: periodic/initial announcement that expects a reply.
  /// `false`: a reply that must never be answered.
  final bool announce;

  /// A send-only probe: `announce:true` with `port:0` (only produced by
  /// [decodeAnnounce] with `allowProbe: true`).
  bool get isProbe => info.port == 0;
}

/// Encodes [self] as a discovery datagram.
///
/// [addrs] overrides `self.addrs` when given. Addresses beyond
/// [kMaxAnnounceAddrs], or that do not fit into [kMaxAnnounceBytes], are dropped
/// from the tail. The alias is sanitised (control characters removed, cut to
/// [kMaxAnnounceAliasLength] code points) so a hostile or sloppy user setting
/// cannot make the device unannounceable.
///
/// With [probe] the datagram is a send-only probe: `port` is written as 0
/// whatever `self.port` says, and [announce] must be true.
///
/// Throws [ArgumentError] when [self] can never form a valid announcement
/// (e.g. port outside 1..65535 without [probe], empty deviceId, oversize
/// non-address fields, a probe with `announce:false`); receivers would
/// silently drop such a datagram.
Uint8List encodeAnnounce(
  DeviceInfo self, {
  required bool announce,
  List<DeviceAddress>? addrs,
  bool probe = false,
}) {
  if (probe && !announce) {
    throw ArgumentError.value(
      announce,
      'announce',
      'a send-only probe (port 0) must have announce:true',
    );
  }
  final candidates = (addrs ?? self.addrs).take(kMaxAnnounceAddrs).toList();
  final alias = _sanitizeAlias(self.alias);
  final fingerprint = self.fingerprint.toUpperCase();

  Uint8List build(int addrCount) {
    final map = <String, Object?>{
      'proto': kProtocolName,
      'v': self.version,
      'deviceId': self.deviceId,
      'alias': alias,
      'platform': self.platform,
      'deviceType': self.deviceType,
      'fingerprint': fingerprint,
      'port': probe ? 0 : self.port,
      'addrs': [for (final a in candidates.take(addrCount)) a.toJson()],
      'caps': self.caps,
      'announce': announce,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(map)));
  }

  var count = candidates.length;
  var bytes = build(count);
  while (bytes.length > kMaxAnnounceBytes && count > 0) {
    count--;
    bytes = build(count);
  }
  // Round-trip through the receiver's rules: anything a peer would drop is a
  // programming error on our side, not something to send into the void.
  if (decodeAnnounce(bytes, allowProbe: probe) == null) {
    throw ArgumentError.value(
      self.deviceId,
      'self',
      'cannot be announced: invalid or oversize fields '
          '(port=${probe ? 0 : self.port}, ${bytes.length} B)',
    );
  }
  return bytes;
}

/// Decodes and validates a discovery datagram; `null` when it must be dropped.
///
/// Drop rules: empty or larger than [kMaxAnnounceBytes]; not UTF-8 / JSON /
/// an object; `proto != "libreshare"`; `v` not `<digits>.<digits>` or major
/// other than `1`; missing or invalid `deviceId`, `alias` (1..64 code points,
/// no control characters), `fingerprint` (empty or 64 hex digits, any case),
/// `port` (integer 1..65535; 0 too when [allowProbe] is set and `announce` is
/// true, see the library docs), `announce` (bool); more than
/// [kMaxAnnounceAddrs] addresses or an address that is not an IPv4/IPv6
/// literal. Unknown members are ignored.
AnnounceMessage? decodeAnnounce(List<int> bytes, {bool allowProbe = false}) {
  try {
    if (bytes.isEmpty || bytes.length > kMaxAnnounceBytes) return null;
    final Object? root = jsonDecode(utf8.decode(bytes));
    if (root is! Map) return null;

    if (root['proto'] != kProtocolName) return null;

    final v = root['v'];
    if (v is! String || !_versionPattern.hasMatch(v)) return null;
    if (v.substring(0, v.indexOf('.')) != '1') return null;

    final deviceId = _text(root['deviceId'], max: _maxIdLength);
    if (deviceId == null) return null;

    final aliasRaw = root['alias'];
    final alias = _text(aliasRaw, max: kMaxAnnounceAliasLength);
    if (alias == null || (aliasRaw as String).trim().isEmpty) return null;

    final platform = root.containsKey('platform')
        ? _text(root['platform'], max: _maxTagLength)
        : 'unknown';
    if (platform == null) return null;

    final deviceType = root.containsKey('deviceType')
        ? _text(root['deviceType'], max: _maxTagLength)
        : 'desktop';
    if (deviceType == null) return null;

    final fpRaw = root['fingerprint'];
    if (fpRaw is! String || !_fingerprintPattern.hasMatch(fpRaw)) return null;

    final announce = root['announce'];
    if (announce is! bool) return null;

    final port = root['port'];
    if (port is! int || port > 65535) return null;
    if (port < 1 && !(allowProbe && port == 0 && announce)) return null;

    final addrs = _addrs(root['addrs']);
    if (addrs == null) return null;

    final caps = _caps(root['caps']);
    if (caps == null) return null;

    return AnnounceMessage(
      DeviceInfo(
        deviceId: deviceId,
        alias: alias,
        platform: platform,
        deviceType: deviceType,
        fingerprint: fpRaw.toUpperCase(),
        port: port,
        addrs: addrs,
        caps: caps,
        version: v,
      ),
      announce: announce,
    );
  } catch (_) {
    // FormatException (UTF-8/JSON), StackOverflow on pathological nesting, ...
    // Hostile input must never escape as an exception.
    return null;
  }
}

final RegExp _versionPattern = RegExp(r'^[0-9]{1,4}\.[0-9]{1,4}$');
final RegExp _fingerprintPattern = RegExp(r'^([0-9A-Fa-f]{64})?$');

List<DeviceAddress>? _addrs(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List || raw.length > kMaxAnnounceAddrs) return null;
  final out = <DeviceAddress>[];
  for (final item in raw) {
    if (item is! Map) return null;
    final ip = item['ip'];
    if (ip is! String || !_isIpLiteral(ip)) return null;
    final iface = item['if'];
    out.add(
      DeviceAddress(
        ip,
        iface: iface is String && _ifaceClasses.contains(iface)
            ? iface
            : 'unknown',
      ),
    );
  }
  return out;
}

List<String>? _caps(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List || raw.length > _maxCaps) return null;
  final out = <String>[];
  for (final item in raw) {
    final c = _text(item, max: _maxTagLength);
    if (c == null) return null;
    out.add(c);
  }
  return out;
}

/// A non-empty string of at most [max] code points without control/format
/// characters, or `null`.
String? _text(Object? raw, {required int max}) {
  if (raw is! String || raw.isEmpty) return null;
  var count = 0;
  for (final r in raw.runes) {
    if (_isForbiddenRune(r) || ++count > max) return null;
  }
  return raw;
}

bool _isIpLiteral(String s) {
  if (s.isEmpty || s.length > 45) return false;
  // Reject zone ids ("fe80::1%eth0"), whitespace and anything that is not a
  // plain literal; InternetAddress.tryParse is lenient about some of these.
  for (final u in s.codeUnits) {
    final ok =
        (u >= 0x30 && u <= 0x39) || // 0-9
        (u >= 0x41 && u <= 0x46) || // A-F
        (u >= 0x61 && u <= 0x66) || // a-f
        u == 0x2e || // .
        u == 0x3a; // :
    if (!ok) return false;
  }
  return InternetAddress.tryParse(s) != null;
}

/// Control characters (C0, DEL, C1), line/paragraph separators, unpaired
/// surrogates and bidi override/isolate marks (alias spoofing).
bool _isForbiddenRune(int r) =>
    r < 0x20 ||
    (r >= 0x7f && r <= 0x9f) ||
    (r >= 0xd800 && r <= 0xdfff) ||
    r == 0x2028 ||
    r == 0x2029 ||
    r == 0x200e ||
    r == 0x200f ||
    (r >= 0x202a && r <= 0x202e) ||
    (r >= 0x2066 && r <= 0x2069);

String _sanitizeAlias(String alias) {
  final kept = <int>[];
  for (final r in alias.runes) {
    if (!_isForbiddenRune(r)) kept.add(r);
  }
  final cut = kept.length > kMaxAnnounceAliasLength
      ? kept.sublist(0, kMaxAnnounceAliasLength)
      : kept;
  final s = String.fromCharCodes(cut).trim();
  return s.isEmpty ? 'LibreShare' : s;
}

// ------------------------------------------------------------ goodbye (bye)

/// A decoded, strictly shaped (but NOT yet verified) `bye` datagram (LSP-1 4.2
/// rule 9). The receiver must check the window, the certificate and
/// [signature] before acting on it.
class ByeMessage {
  const ByeMessage({
    required this.deviceId,
    required this.fingerprint,
    required this.ts,
    required this.signature,
  });

  final String deviceId;

  /// Uppercase 64-hex fingerprint of the sender's certificate.
  final String fingerprint;

  /// Sender clock, Unix epoch milliseconds.
  final int ts;

  /// Raw ECDSA P-256 r||s (64 bytes).
  final Uint8List signature;
}

/// Version a device reports in a `bye` (the secure profile, LSP/1.1).
const String _byeVersion = '1.1';

/// The text a `bye` signature covers: deviceId + fingerprint + ts, UTF-8, no
/// separators (LSP-1 4.2 rule 9).
List<int> _byeText(String deviceId, String fingerprint, int ts) =>
    utf8.encode('$deviceId$fingerprint$ts');

/// Text signed by a `bye` (exposed for the receiver's verification).
List<int> byeSignedText(ByeMessage m) =>
    _byeText(m.deviceId, m.fingerprint, m.ts);

/// Builds the `bye` datagram of [identity] at [now] (LSP-1 4.2 rule 9): a
/// signature over domain `LSP1-BYE` + NUL + deviceId + fingerprint + ts.
Uint8List encodeBye(IdentityProvider identity, {required DateTime now}) {
  final id = identity.identity;
  final ts = now.toUtc().millisecondsSinceEpoch;
  final fingerprint = id.fingerprint.toUpperCase();
  final sig = identity.sign(
    SigDomain.bye,
    _byeText(id.deviceId, fingerprint, ts),
  );
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'proto': kProtocolName,
        'v': _byeVersion,
        't': 'bye',
        'deviceId': id.deviceId,
        'fingerprint': fingerprint,
        'ts': ts,
        'sig': b64urlEncode(sig),
      }),
    ),
  );
}

final RegExp _byeFingerprint = RegExp(r'^[0-9A-F]{64}$');
final RegExp _byeSig = RegExp(r'^[A-Za-z0-9_-]{86}$');

/// Decodes a `bye` datagram; `null` for anything that is not exactly the
/// schema's `bye` branch. Never throws. Does not verify the signature.
ByeMessage? decodeBye(List<int> bytes) {
  try {
    if (bytes.isEmpty || bytes.length > kMaxAnnounceBytes) return null;
    final Object? root = jsonDecode(utf8.decode(bytes));
    if (root is! Map) return null;
    if (root['proto'] != kProtocolName) return null;
    if (root['t'] != 'bye') return null;
    if (root.containsKey('announce')) return null;

    final v = root['v'];
    if (v is! String || !_versionPattern.hasMatch(v)) return null;
    final dot = v.indexOf('.');
    if (v.substring(0, dot) != '1') return null;
    if (int.parse(v.substring(dot + 1)) < 1) return null;

    final deviceId = _text(root['deviceId'], max: _maxIdLength);
    if (deviceId == null) return null;

    final fp = root['fingerprint'];
    if (fp is! String || !_byeFingerprint.hasMatch(fp)) return null;

    final ts = root['ts'];
    if (ts is! int || ts < 0) return null;

    final sig = root['sig'];
    if (sig is! String || !_byeSig.hasMatch(sig)) return null;
    final raw = b64urlDecode(sig);
    if (raw.length != 64) return null;

    return ByeMessage(
      deviceId: deviceId,
      fingerprint: fp,
      ts: ts,
      signature: raw,
    );
  } catch (_) {
    return null;
  }
}
