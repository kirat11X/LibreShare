import 'dart:typed_data';

/// LibreShare BLE beacon constants per design 03 section 3.2.
const int kBleCompanyIdSigTest = 0xFFFF;
const int kBleMagicByte0 = 0x4C; // 'L'
const int kBleMagicByte1 = 0x53; // 'S'
const int kBleBeaconLength = 16;
const int kBleBeaconVersion = 1;

/// Flags field in the LibreShare BLE beacon (Offset 4, lower 4 bits).
class BeaconFlags {
  const BeaconFlags({
    this.recv = false,
    this.send = false,
    this.open = false,
    this.gatt = false,
  });

  final bool recv;
  final bool send;
  final bool open;
  final bool gatt;

  int toBits() {
    var b = 0;
    if (recv) b |= (1 << 0);
    if (send) b |= (1 << 1);
    if (open) b |= (1 << 2);
    if (gatt) b |= (1 << 3);
    return b & 0x0F;
  }

  factory BeaconFlags.fromBits(int bits) {
    return BeaconFlags(
      recv: (bits & (1 << 0)) != 0,
      send: (bits & (1 << 1)) != 0,
      open: (bits & (1 << 2)) != 0,
      gatt: (bits & (1 << 3)) != 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BeaconFlags &&
          recv == other.recv &&
          send == other.send &&
          open == other.open &&
          gatt == other.gatt;

  @override
  int get hashCode => Object.hash(recv, send, open, gatt);

  @override
  String toString() =>
      'BeaconFlags(recv: $recv, send: $send, open: $open, gatt: $gatt)';
}

/// Platform code in the LibreShare BLE beacon capabilities.
enum BlePlatform {
  linux(0),
  windows(1),
  android(2),
  macos(3),
  ios(4),
  other(5);

  const BlePlatform(this.code);
  final int code;

  static BlePlatform fromCode(int code) {
    for (final p in values) {
      if (p.code == code) return p;
    }
    return other;
  }
}

/// Capabilities field in the LibreShare BLE beacon (Offset 5).
class BeaconCap {
  const BeaconCap({
    this.canHost = false,
    this.canJoin = false,
    this.hostKeepsUplink = false,
    this.platform = BlePlatform.linux,
  });

  final bool canHost;
  final bool canJoin;
  final bool hostKeepsUplink;
  final BlePlatform platform;

  int toBits() {
    var b = 0;
    if (canHost) b |= (1 << 0);
    if (canJoin) b |= (1 << 1);
    if (hostKeepsUplink) b |= (1 << 2);
    b |= (platform.code & 0x07) << 3;
    return b & 0xFF;
  }

  factory BeaconCap.fromBits(int bits) {
    return BeaconCap(
      canHost: (bits & (1 << 0)) != 0,
      canJoin: (bits & (1 << 1)) != 0,
      hostKeepsUplink: (bits & (1 << 2)) != 0,
      platform: BlePlatform.fromCode((bits >> 3) & 0x07),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BeaconCap &&
          canHost == other.canHost &&
          canJoin == other.canJoin &&
          hostKeepsUplink == other.hostKeepsUplink &&
          platform == other.platform;

  @override
  int get hashCode => Object.hash(canHost, canJoin, hostKeepsUplink, platform);

  @override
  String toString() =>
      'BeaconCap(canHost: $canHost, canJoin: $canJoin, hostKeepsUplink: $hostKeepsUplink, platform: $platform)';
}

/// Decoded LibreShare BLE beacon representation.
class BleBeacon {
  BleBeacon({
    this.companyId = kBleCompanyIdSigTest,
    this.version = kBleBeaconVersion,
    required this.flags,
    required this.cap,
    required List<int> eid,
    required this.seq,
  }) : eid = Uint8List.fromList(eid) {
    if (this.eid.length != 8) {
      throw ArgumentError.value(
        eid.length,
        'eid',
        'EID must be exactly 8 bytes',
      );
    }
    if (seq < 0 || seq > 0xFFFF) {
      throw ArgumentError.value(seq, 'seq', 'seq must be uint16 (0..65535)');
    }
  }

  final int companyId;
  final int version;
  final BeaconFlags flags;
  final BeaconCap cap;
  final Uint8List eid;
  final int seq;

  /// Serializes the beacon to raw manufacturer bytes.
  Uint8List toBytes() {
    final buffer = ByteData(kBleBeaconLength);
    // Company ID: 2 bytes little-endian
    buffer.setUint16(0, companyId, Endian.little);
    // Magic: "LS"
    buffer.setUint8(2, kBleMagicByte0);
    buffer.setUint8(3, kBleMagicByte1);
    // Version and Flags
    final vFlags = ((version & 0x0F) << 4) | (flags.toBits() & 0x0F);
    buffer.setUint8(4, vFlags);
    // Capabilities
    buffer.setUint8(5, cap.toBits());
    // EID: 8 bytes
    final bytes = buffer.buffer.asUint8List();
    bytes.setRange(6, 14, eid);
    // Seq: 2 bytes little-endian
    buffer.setUint16(14, seq, Endian.little);
    return bytes;
  }

  /// Deserializes a beacon from manufacturer bytes. Returns null if invalid length or magic.
  static BleBeacon? fromBytes(
    List<int> bytes, {
    int expectedCompanyId = kBleCompanyIdSigTest,
  }) {
    if (bytes.length < kBleBeaconLength) return null;
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final cid = data.getUint16(0, Endian.little);
    if (expectedCompanyId != 0 && cid != expectedCompanyId) return null;

    final m0 = data.getUint8(2);
    final m1 = data.getUint8(3);
    if (m0 != kBleMagicByte0 || m1 != kBleMagicByte1) return null;

    final vFlags = data.getUint8(4);
    final ver = (vFlags >> 4) & 0x0F;
    final flagsBits = vFlags & 0x0F;
    final capBits = data.getUint8(5);
    final eidBytes = Uint8List.sublistView(data.buffer.asUint8List(), 6, 14);
    final seq = data.getUint16(14, Endian.little);

    return BleBeacon(
      companyId: cid,
      version: ver,
      flags: BeaconFlags.fromBits(flagsBits),
      cap: BeaconCap.fromBits(capBits),
      eid: eidBytes,
      seq: seq,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BleBeacon &&
          companyId == other.companyId &&
          version == other.version &&
          flags == other.flags &&
          cap == other.cap &&
          _bytesEqual(eid, other.eid) &&
          seq == other.seq;

  @override
  int get hashCode =>
      Object.hash(companyId, version, flags, cap, Object.hashAll(eid), seq);

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
