enum CameraFileFormat {
  raw,
  jpeg,
  png,
  mp4,
  avchd,
  other;

  static CameraFileFormat fromFileName(String name) {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex == name.length - 1) {
      return CameraFileFormat.other;
    }

    final extension = name.substring(dotIndex + 1).toLowerCase();

    return switch (extension) {
      'arw' => CameraFileFormat.raw,
      'jpg' || 'jpeg' => CameraFileFormat.jpeg,
      'png' => CameraFileFormat.png,
      'mp4' => CameraFileFormat.mp4,
      'mts' || 'm2ts' => CameraFileFormat.avchd,
      _ => CameraFileFormat.other,
    };
  }
}

final class CameraFile {
  const CameraFile({
    required this.id,
    required this.name,
    required this.extension,
    required this.format,
    required this.byteLength,
    this.capturedAt,
    this.duration,
    this.thumbnailKey,
    this.directory,
  });

  final String id;
  final String name;
  final String extension;
  final CameraFileFormat format;
  final int byteLength;
  final DateTime? capturedAt;
  final Duration? duration;
  final String? thumbnailKey;

  /// Camera/storage/directory scope. The display filename remains unchanged.
  final String? directory;
}
