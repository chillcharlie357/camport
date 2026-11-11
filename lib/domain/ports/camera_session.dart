import '../models/camera_file.dart';
import '../models/camera_profile.dart';
import 'camera_adapter.dart';

/// A connected camera has its own protocol, source identity, and lifecycle.
/// The gallery and transfer queue operate through this boundary regardless of
/// camera brand. An implementation must reject downloads if the source changed.
abstract interface class CameraSession implements CameraAdapter {
  bool get connected;
  CameraProfile? get profile;
  String? get cacheNamespace;
  Future<CameraFile> describeFile(String fileId);
  void expectFile(String fileId, {String? sourceVersion, int? byteLength});
  Future<void> close();
}
