final class CameraCapabilities {
  const CameraCapabilities({
    required this.canListFiles,
    required this.hasThumbnails,
    required this.canDownloadOriginals,
    required this.canRemoteControl,
    required this.hasLiveView,
  });

  final bool canListFiles;
  final bool hasThumbnails;
  final bool canDownloadOriginals;
  final bool canRemoteControl;
  final bool hasLiveView;
}
