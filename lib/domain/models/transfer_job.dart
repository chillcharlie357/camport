enum TransferState {
  queued,
  connecting,
  copying,
  interrupted,
  completed,
  cancelled,
  failed,
}

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
  });

  final String id;
  final String cameraFileId;
  final String destinationPath;
  final TransferState state;
  final int bytesTransferred;
  final int totalBytes;
  final int attemptCount;
  final String? lastError;
}
