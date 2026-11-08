enum ShareMode {
  oneTime(1),
  multiReceiver(2),
  anyone(0);

  const ShareMode(this.wireValue);
  final int wireValue;
}

final class ShareRecord {
  final String shareId;
  final String token;
  final int maxReceivers;
  final int createdAtUnixSeconds;
  final int? expiresAtUnixSeconds;
  final int totalBytes;
  final List<String> fileNames;

  const ShareRecord({
    required this.shareId,
    required this.token,
    required this.maxReceivers,
    required this.createdAtUnixSeconds,
    this.expiresAtUnixSeconds,
    required this.totalBytes,
    required this.fileNames,
  });

  Map<String, dynamic> toJson() => {
    'shareId': shareId,
    'token': token,
    'maxReceivers': maxReceivers,
    'createdAt': createdAtUnixSeconds,
    if (expiresAtUnixSeconds != null) 'expiresAt': expiresAtUnixSeconds,
    'totalBytes': totalBytes,
    'files': fileNames,
  };

  factory ShareRecord.fromJson(Map<String, dynamic> json) {
    return ShareRecord(
      shareId: json['shareId'] as String,
      token: json['token'] as String,
      maxReceivers: (json['maxReceivers'] as num?)?.toInt() ?? 1,
      createdAtUnixSeconds: (json['createdAt'] as num).toInt(),
      expiresAtUnixSeconds: (json['expiresAt'] as num?)?.toInt(),
      totalBytes: (json['totalBytes'] as num).toInt(),
      fileNames: (json['files'] as List<dynamic>)
          .map((e) => e.toString())
          .toList(),
    );
  }

  @override
  String toString() =>
      'ShareRecord(shareId: $shareId, token: [redacted], files: ${fileNames.length})';
}
