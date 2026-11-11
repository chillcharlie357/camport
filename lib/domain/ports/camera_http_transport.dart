import 'dart:typed_data';

import '../models/transfer_progress.dart';

/// Performs protocol-agnostic HTTP operations for camera adapters.
abstract interface class CameraHttpTransport {
  Future<String> getText(Uri uri);

  Future<String> postJson(Uri uri, Map<String, Object?> body);

  Future<Uint8List> getBytes(Uri uri);

  Stream<TransferProgress> downloadToFile(Uri uri, String temporaryPath);
}
