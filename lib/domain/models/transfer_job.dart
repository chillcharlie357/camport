enum TransferState {
  queued,
  connecting,
  copying,
  interrupted,
  completed,
  cancelled,
  failed,
}

/// Durable identity and local import state. [checksum] is a SHA-256 of the
/// downloaded local bytes, not a checksum supplied or verified by the camera.
final class TransferJob {
  const TransferJob({
    required this.id,
    required this.cameraFileId,
    required this.destinationPath,
    required this.state,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.attemptCount,
    this.lastError,
    this.cameraId = '',
    this.fileName = '',
    this.sourceVersion,
    this.sourceCapturedAt,
    this.checksum,
    this.temporaryPath,
    this.commitPending = false,
  });

  final String id;
  final String cameraFileId;
  final String destinationPath;
  final TransferState state;
  final int bytesTransferred;
  final int totalBytes;
  final int attemptCount;
  final String? lastError;
  final String cameraId;
  final String fileName;
  final String? sourceVersion;
  final DateTime? sourceCapturedAt;
  final String? checksum;
  final String? temporaryPath;

  /// Persisted before the atomic file rename, cleared after completion is saved.
  final bool commitPending;

  TransferJob copyWith({
    TransferState? state,
    int? bytesTransferred,
    int? attemptCount,
    String? destinationPath,
    String? fileName,
    String? checksum,
    bool clearChecksum = false,
    String? temporaryPath,
    bool? commitPending,
    String? lastError,
    bool clearError = false,
  }) => TransferJob(
    id: id,
    cameraFileId: cameraFileId,
    cameraId: cameraId,
    destinationPath: destinationPath ?? this.destinationPath,
    fileName: fileName ?? this.fileName,
    state: state ?? this.state,
    bytesTransferred: bytesTransferred ?? this.bytesTransferred,
    totalBytes: totalBytes,
    attemptCount: attemptCount ?? this.attemptCount,
    sourceVersion: sourceVersion,
    sourceCapturedAt: sourceCapturedAt,
    checksum: clearChecksum ? null : checksum ?? this.checksum,
    temporaryPath: temporaryPath ?? this.temporaryPath,
    commitPending: commitPending ?? this.commitPending,
    lastError: clearError ? null : lastError ?? this.lastError,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'cameraFileId': cameraFileId,
    'cameraId': cameraId,
    'fileName': fileName,
    'destinationPath': destinationPath,
    'state': state.name,
    'bytesTransferred': bytesTransferred,
    'totalBytes': totalBytes,
    'attemptCount': attemptCount,
    'lastError': lastError,
    'sourceVersion': sourceVersion,
    'sourceCapturedAt': sourceCapturedAt?.toUtc().toIso8601String(),
    'checksum': checksum,
    'temporaryPath': temporaryPath,
    'commitPending': commitPending,
  };

  factory TransferJob.fromJson(Map<String, dynamic> json) {
    final result = TransferJob(
      id: json['id'] as String,
      cameraFileId: json['cameraFileId'] as String,
      destinationPath: json['destinationPath'] as String,
      state: TransferState.values.byName(json['state'] as String),
      bytesTransferred: json['bytesTransferred'] as int,
      totalBytes: json['totalBytes'] as int,
      attemptCount: json['attemptCount'] as int,
      lastError: json['lastError'] as String?,
      cameraId: json['cameraId'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
      sourceVersion: json['sourceVersion'] as String?,
      sourceCapturedAt: json['sourceCapturedAt'] == null
          ? null
          : DateTime.parse(json['sourceCapturedAt'] as String),
      checksum: json['checksum'] as String?,
      temporaryPath: json['temporaryPath'] as String?,
      commitPending: json['commitPending'] as bool? ?? false,
    );
    if (result.id.isEmpty ||
        result.totalBytes < 0 ||
        result.bytesTransferred < 0 ||
        result.attemptCount < 0 ||
        (result.checksum != null &&
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(result.checksum!))) {
      throw const FormatException('Invalid transfer job');
    }
    return result;
  }
}
