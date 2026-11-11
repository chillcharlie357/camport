import 'dart:convert';

import 'camera_file.dart';
import 'gallery_entry.dart' as gallery;

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
    this.sourceName,
    this.sourceDirectory,
    this.photoIdentity,
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

  /// Names and directory are the camera's original metadata, never the
  /// collision-adjusted local destination filename.
  final String? sourceName;
  final String? sourceDirectory;

  /// Stable same-name photo group used to associate future local metadata work.
  final String? photoIdentity;
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
    sourceName: sourceName,
    sourceDirectory: sourceDirectory,
    photoIdentity: photoIdentity,
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
    'sourceName': sourceName,
    'sourceDirectory': sourceDirectory,
    'photoIdentity': photoIdentity,
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
      sourceName: json['sourceName'] as String?,
      sourceDirectory: json['sourceDirectory'] as String?,
      photoIdentity: json['photoIdentity'] as String?,
      sourceCapturedAt: json['sourceCapturedAt'] == null
          ? null
          : DateTime.parse(json['sourceCapturedAt'] as String),
      checksum: json['checksum'] as String?,
      temporaryPath: json['temporaryPath'] as String?,
      commitPending: json['commitPending'] as bool? ?? false,
    );
    if (result.photoIdentity != null) {
      if (result.photoIdentity!.length > 4096) {
        throw const FormatException('Invalid photo identity');
      }
      // Older queue snapshots have no sourceName. They remain importable, but
      // cannot be trusted for a future metadata write to a physical original.
      if (result.sourceName != null) {
        final source = CameraFile(
          id: result.cameraFileId,
          name: result.sourceName!,
          extension: '',
          format: CameraFileFormat.fromFileName(result.sourceName!),
          byteLength: result.totalBytes,
          thumbnailKey: result.sourceVersion,
          directory: result.sourceDirectory,
        );
        if (!gallery.isPhoto(source) ||
            gallery.photoIdentity(source, cameraId: result.cameraId) !=
                result.photoIdentity) {
          throw const FormatException(
            'Photo identity differs from camera source',
          );
        }
      } else {
        try {
          final parts = jsonDecode(result.photoIdentity!);
          if (parts is! List ||
              parts.length != 3 ||
              parts[0] != 'photo' ||
              parts[1] is! String ||
              parts[2] is! String ||
              (parts[2] as String).isEmpty) {
            throw const FormatException('Invalid legacy photo identity');
          }
        } on FormatException {
          throw const FormatException('Invalid legacy photo identity');
        }
      }
    }
    if (result.id.isEmpty ||
        result.totalBytes < 0 ||
        result.bytesTransferred < 0 ||
        result.attemptCount < 0 ||
        (result.sourceName != null &&
            (result.sourceName!.isEmpty ||
                result.sourceName!.length > 1024 ||
                result.sourceName!.contains(RegExp(r'[/\\\x00]')))) ||
        (result.sourceDirectory != null &&
            result.sourceDirectory!.length > 2048) ||
        (result.checksum != null &&
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(result.checksum!))) {
      throw const FormatException('Invalid transfer job');
    }
    return result;
  }
}
