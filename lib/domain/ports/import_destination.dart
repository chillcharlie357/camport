import '../models/camera_file.dart';

/// Manages temporary and published files in the chosen import destination.
abstract interface class ImportDestination {
  Future<String> createTemporaryFile(CameraFile file);

  Future<void> publishCompletedFile(String temporaryPath, CameraFile file);

  Future<void> discardTemporaryFile(String temporaryPath);
}
