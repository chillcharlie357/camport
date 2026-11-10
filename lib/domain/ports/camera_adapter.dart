import 'dart:typed_data';

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
  Future<CameraProfile> connect(CameraProfile profile);

  Future<CameraCapabilities> discoverCapabilities();

  Future<CameraPage<CameraFile>> listFiles({String? cursor});

  /// Returns preview-sized thumbnail bytes; original media must not pass here.
  Future<Uint8List?> loadThumbnail(String fileId);

  Stream<TransferProgress> downloadOriginal(
    String fileId,
    String destinationPath,
  );
}
