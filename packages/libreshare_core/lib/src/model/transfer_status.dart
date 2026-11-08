/// Exactly the four UML states (spec §2.3); causes live in [FailureReason].
library;

enum TransferStatus {
  pending('PENDING'),
  inProgress('IN_PROGRESS'),
  completed('COMPLETED'),
  failed('FAILED');

  const TransferStatus(this.wire);
  final String wire;
  static TransferStatus fromWire(String w) =>
      TransferStatus.values.firstWhere((s) => s.wire == w);
  bool get isTerminal => this == completed || this == failed;
}

enum FailureReason {
  rejected('REJECTED'),
  timeout('TIMEOUT'),
  cancelled('CANCELLED'),
  verifyFailed('VERIFY_FAILED'),
  noConnection('NO_CONNECTION'),
  diskFull('DISK_FULL'),
  storageUnusable('STORAGE_UNUSABLE'),
  protocolError('PROTOCOL_ERROR');

  const FailureReason(this.wire);
  final String wire;
  static FailureReason? fromWire(String? w) =>
      w == null ? null : FailureReason.values.firstWhere((r) => r.wire == w);
}
