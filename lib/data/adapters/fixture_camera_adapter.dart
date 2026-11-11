import 'dart:typed_data';

import '../../domain/models/camera_capabilities.dart';
import '../../domain/models/camera_file.dart';
import '../../domain/models/camera_page.dart';
import '../../domain/models/camera_profile.dart';
import '../../domain/models/transfer_progress.dart';
import '../../domain/ports/camera_adapter.dart';

/// A local-only gallery source. It never contacts or represents a camera.
final class FixtureCameraAdapter implements CameraAdapter {
  static final List<CameraFile> files = List<CameraFile>.unmodifiable([
    ...List.generate(6, (index) {
      final number = (index + 1).toString().padLeft(4, '0');
      final name = 'DSC_$number.ARW';
      return CameraFile(
        id: 'raw-${index + 1}',
        name: name,
        extension: 'ARW',
        format: CameraFileFormat.fromFileName(name),
        byteLength: 24_000_000 + index * 137_000,
        thumbnailKey: 'placeholder:raw-${index + 1}',
      );
    }),
    ...List.generate(14, (index) {
      final number = (index + 1).toString().padLeft(4, '0');
      final extension = index == 5 ? 'PNG' : 'JPG';
      final name = 'DSC_$number.$extension';
      return CameraFile(
        id: 'jpeg-${index + 1}',
        name: name,
        extension: extension,
        format: CameraFileFormat.fromFileName(name),
        byteLength: 5_200_000 + index * 31_000,
        thumbnailKey: 'placeholder:jpeg-${index + 1}',
      );
    }),
    ...List.generate(4, (index) {
      final number = (index + 1).toString().padLeft(4, '0');
      final name = 'C$number.MP4';
      return CameraFile(
        id: 'mp4-${index + 1}',
        name: name,
        extension: 'MP4',
        format: CameraFileFormat.fromFileName(name),
        byteLength: 83_000_000 + index * 2_100_000,
        duration: Duration(seconds: 18 + index * 7),
        thumbnailKey: 'placeholder:mp4-${index + 1}',
      );
    }),
  ]);

  @override
  Future<CameraProfile> connect(CameraProfile profile) =>
      Future<CameraProfile>.error(UnsupportedError('示例图库不会连接相机。'));

  @override
  Future<CameraCapabilities> discoverCapabilities() async =>
      const CameraCapabilities(
        canListFiles: true,
        hasThumbnails: false,
        canDownloadOriginals: false,
        canRemoteControl: false,
        hasLiveView: false,
      );

  @override
  Future<CameraPage<CameraFile>> listFiles({String? cursor}) async =>
      CameraPage<CameraFile>(items: cursor == null ? files : const []);

  @override
  Future<Uint8List?> loadThumbnail(String fileId) async => null;

  @override
  Stream<TransferProgress> downloadOriginal(
    String fileId,
    String destinationPath,
  ) => Stream<TransferProgress>.error(UnsupportedError('示例文件不会被传输。'));
}
