import 'dart:typed_data';

import 'camera_http_transport.dart' show CameraHttpTransport;
import '../models/camera_capabilities.dart';
import '../models/camera_file.dart';
import '../models/camera_page.dart';
import '../models/camera_profile.dart';
import '../models/transfer_progress.dart';

/// Describes the capabilities and media operations supported by a camera.
///
/// Protocol adapters should receive a [CameraHttpTransport] through their
/// constructor so request construction remains outside widgets.
abstract interface class CameraAdapter {
  /// Maximum longest edge, in source pixels, for a returned thumbnail.
  static const int maxThumbnailEdge = 512;

  Future<CameraProfile> connect(CameraProfile profile);

  Future<CameraCapabilities> discoverCapabilities();

  Future<CameraPage<CameraFile>> listFiles({String? cursor});

  /// Returns encoded preview bytes with a longest source-image edge no greater
  /// than [maxThumbnailEdge] pixels. Original media must never be returned.
  Future<Uint8List?> loadThumbnail(String fileId);

  Stream<TransferProgress> downloadOriginal(
    String fileId,
    String destinationPath,
  );
}
