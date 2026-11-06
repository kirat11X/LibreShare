library;

/// FileItem (UML 5.0): one entry of a manifest.
class FileItem {
  const FileItem({
    required this.fileId,
    required this.fileName,
    required this.size,
    required this.chunkCount,
    this.relativePath,
    this.mime = 'application/octet-stream',
    this.sha256, // 64 lowercase hex, or null for >2 GiB (supplied at /complete)
    this.modified,
  });

  final String fileId;
  final String fileName;
  final String? relativePath;
  final int size;
  final String mime;
  final String? sha256;
  final int chunkCount;
  final DateTime? modified;

  Map<String, Object?> toJson() => {
    'fileId': fileId,
    'fileName': fileName,
    'relativePath': relativePath,
    'size': size,
    'mime': mime,
    'sha256': sha256,
    'chunkCount': chunkCount,
    'modified': modified?.toUtc().toIso8601String(),
  };

  factory FileItem.fromJson(Map<String, Object?> j) => FileItem(
    fileId: j['fileId']! as String,
    fileName: j['fileName']! as String,
    relativePath: j['relativePath'] as String?,
    size: j['size']! as int,
    mime: (j['mime'] as String?) ?? 'application/octet-stream',
    sha256: j['sha256'] as String?,
    chunkCount: j['chunkCount']! as int,
    modified: j['modified'] == null
        ? null
        : DateTime.parse(j['modified']! as String),
  );
}
