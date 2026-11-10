enum CameraFileFormat {
  raw,
  jpeg,
  mp4,
  avchd,
  other;

  static CameraFileFormat fromFilename(String filename) {
    final extension = filename
        .substring(filename.lastIndexOf('.') + 1)
        .toLowerCase();

    return switch (extension) {
      'arw' => CameraFileFormat.raw,
      'jpg' || 'jpeg' => CameraFileFormat.jpeg,
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
  });

  final String id;
  final String name;
  final String extension;
  final CameraFileFormat format;
  final int byteLength;
  final DateTime? capturedAt;
  final Duration? duration;
  final String? thumbnailKey;
}
