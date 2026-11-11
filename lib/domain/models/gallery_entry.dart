import 'dart:convert';

import 'camera_file.dart';

bool isPhoto(CameraFile file) => switch (file.format) {
  CameraFileFormat.raw || CameraFileFormat.jpeg || CameraFileFormat.png => true,
  _ => false,
};

/// The simple photo rule: same directory + case-insensitive basename, stripping
/// only the final extension. No camera metadata or capture time is required.
String photoIdentity(CameraFile file) {
  final path = file.name.replaceAll('\\', '/');
  final slash = path.lastIndexOf('/');
  final name = path.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  final stem = dot < 0 ? name : name.substring(0, dot);
  if (isPhoto(file) && stem.trim().isNotEmpty) {
    return jsonEncode([
      'photo',
      file.directory == null
          ? path.substring(0, slash + 1)
          : '${file.directory}/${path.substring(0, slash + 1)}',
      stem.toLowerCase(),
    ]);
  }
  return jsonEncode(['file', file.id]);
}

Map<String, String> photoIdentities(List<CameraFile> files) =>
    Map.unmodifiable({for (final file in files) file.id: photoIdentity(file)});

String cameraFormatLabel(CameraFileFormat format) => switch (format) {
  CameraFileFormat.raw => 'RAW',
  CameraFileFormat.jpeg => 'JPEG',
  CameraFileFormat.png => 'PNG',
  CameraFileFormat.mp4 => 'MP4',
  CameraFileFormat.avchd => 'AVCHD',
  CameraFileFormat.other => '其他',
};

/// One immutable display item; members include only physical files that passed
/// the current format filter. Selection always uses the underlying file ids.
final class GalleryEntry {
  GalleryEntry({required this.identity, required Iterable<CameraFile> members})
    : members = List.unmodifiable(members);

  final String identity;
  final List<CameraFile> members;
  CameraFile get representative => members.firstWhere(
    (file) =>
        file.format == CameraFileFormat.jpeg ||
        file.format == CameraFileFormat.png,
    orElse: () => members.first,
  );
  bool get isPhotoEntry => isPhoto(representative);
  String get formatLabel =>
      members.map((f) => f.format).toSet().map(cameraFormatLabel).join(' + ');
  int get byteLength => members.fold(0, (sum, file) => sum + file.byteLength);
}

List<GalleryEntry> galleryEntries({
  required List<CameraFile> files,
  required Map<String, String> identities,
  required bool merge,
}) {
  final candidates = <String, List<CameraFile>>{};
  for (final file in files) {
    candidates.putIfAbsent(identities[file.id]!, () => []).add(file);
  }
  final mergeKeys = {
    if (merge)
      for (final group in candidates.entries)
        if (group.value.any((f) => f.format == CameraFileFormat.raw) &&
            group.value.any(
              (f) =>
                  f.format == CameraFileFormat.jpeg ||
                  f.format == CameraFileFormat.png,
            ))
          group.key,
  };
  final groups = <String, List<CameraFile>>{};
  for (final file in files) {
    final identity = identities[file.id]!;
    final displayKey = mergeKeys.contains(identity)
        ? identity
        : jsonEncode(['file', file.id]);
    groups.putIfAbsent(displayKey, () => []).add(file);
  }
  return List.unmodifiable([
    for (final members in groups.values)
      GalleryEntry(identity: identities[members.first.id]!, members: members),
  ]);
}
