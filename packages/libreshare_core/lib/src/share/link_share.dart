import 'dart:typed_data';

import '../model/share_models.dart';

enum LinkShareState { ready, active, completed, revoked, expired }

class LinkShare {
  final String shareId;
  final String token;
  final Uint8List rootKey;
  final ShareMode mode;
  final int maxReceivers;
  final int totalBytes;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final List<String> fileNames;

  LinkShareState _state = LinkShareState.ready;
  LinkShareState get state => _state;

  final Set<String> _boundClaims = {};
  Set<String> get boundClaims => Set.unmodifiable(_boundClaims);

  final Map<String, int> _bytesPerClaim = {};
  int _totalBytesServed = 0;
  int get totalBytesServed => _totalBytesServed;

  bool get isCompleted => _state == LinkShareState.completed;
  bool get isRevoked => _state == LinkShareState.revoked;

  int get maxAllowedBudget {
    final factor = maxReceivers == 0 ? 10 : maxReceivers;
    return 2 * totalBytes * factor;
  }

  LinkShare({
    required this.shareId,
    required this.token,
    required this.rootKey,
    required this.mode,
    required this.maxReceivers,
    required this.totalBytes,
    required this.createdAt,
    this.expiresAt,
    required this.fileNames,
  });

  bool tryBindClaim(String claim) {
    if (isCompleted || isRevoked) return false;
    if (maxReceivers == 1) {
      if (_boundClaims.isEmpty) {
        _boundClaims.add(claim);
        _state = LinkShareState.active;
        return true;
      }
      return _boundClaims.contains(claim);
    } else if (maxReceivers > 1) {
      if (_boundClaims.length < maxReceivers || _boundClaims.contains(claim)) {
        _boundClaims.add(claim);
        _state = LinkShareState.active;
        return true;
      }
      return false;
    } else {
      // mode anyone (maxReceivers == 0)
      _boundClaims.add(claim);
      _state = LinkShareState.active;
      return true;
    }
  }

  void recordBytesServed(String claim, int bytes) {
    if (isCompleted || isRevoked) return;
    _bytesPerClaim[claim] = (_bytesPerClaim[claim] ?? 0) + bytes;
    _totalBytesServed += bytes;
    if (_totalBytesServed >= maxAllowedBudget) {
      revoke(reason: 'Byte budget exceeded');
    }
  }

  void recordFinalAck(String claim) {
    if (isRevoked) return;
    if (mode == ShareMode.oneTime || maxReceivers == 1) {
      _state = LinkShareState.completed;
    }
  }

  void revoke({String reason = 'manual'}) {
    _state = LinkShareState.revoked;
  }

  bool isExpired(DateTime now) {
    if (expiresAt == null) return false;
    return now.isAfter(expiresAt!);
  }

  @override
  String toString() =>
      'LinkShare(shareId: $shareId, token: [redacted], state: $_state)';
}
