/// Transfer speed modes (docs/plans/inc4-speed.md, wave S3). A mode is a LOCAL
/// setting of the device that runs the transfer; it is never sent on the wire
/// and never relaxes TLS, PIN or integrity checks. Measured on loopback
/// (300 MiB): 1 chunk in flight 75/109 MiB/s (secure/plain), 3 in flight
/// 85/134, 8 in flight 86/143.
library;

/// How hard a transfer pushes the CPU, disk and network of this device.
enum SpeedMode {
  /// Gentle: one chunk in flight. For batteries, old CPUs, slow media.
  eco,

  /// Default: three chunks in flight.
  balanced,

  /// Fastest: eight chunks in flight. For SSDs and fast links.
  turbo,
}

/// The mode used when nothing was chosen.
const SpeedMode kDefaultSpeedMode = SpeedMode.balanced;

/// What a [SpeedMode] means in numbers.
class SpeedProfile {
  const SpeedProfile({required this.chunkConcurrency});

  /// Chunks PUT in parallel per file (FileSender.chunkConcurrency).
  final int chunkConcurrency;
}

/// The numbers behind [mode].
SpeedProfile speedProfileFor(SpeedMode mode) => switch (mode) {
  SpeedMode.eco => const SpeedProfile(chunkConcurrency: 1),
  SpeedMode.balanced => const SpeedProfile(chunkConcurrency: 3),
  SpeedMode.turbo => const SpeedProfile(chunkConcurrency: 8),
};

/// Parses a user-typed mode name, case-insensitive and trimmed. Accepts
/// `eco` (alias `slow`), `balanced` (aliases `normal`, `default`) and `turbo`
/// (aliases `fast`, `high`). Returns null for null, empty or unknown text.
SpeedMode? parseSpeedMode(String? text) {
  switch (text?.trim().toLowerCase()) {
    case 'eco':
    case 'slow':
      return SpeedMode.eco;
    case 'balanced':
    case 'normal':
    case 'default':
      return SpeedMode.balanced;
    case 'turbo':
    case 'fast':
    case 'high':
      return SpeedMode.turbo;
  }
  return null;
}
