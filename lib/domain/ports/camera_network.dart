import '../models/camera_profile.dart';

/// Provides access to and reachability checks for a camera's network.
abstract interface class CameraNetwork {
  Future<NetworkConnectionResult> joinCameraNetwork(CameraProfile profile);

  Future<bool> isCameraReachable(CameraProfile profile);

  Future<void> releaseCameraNetwork();
}
