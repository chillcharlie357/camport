import 'dart:typed_data';

import '../models/camera_file.dart';

/// A live session may reject an old viewport revision after reconnecting.
abstract interface class VersionedThumbnailSource {
  Future<Uint8List?> loadVersionedThumbnail(CameraFile file);
}
