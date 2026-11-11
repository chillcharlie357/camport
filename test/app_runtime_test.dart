import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sony_camera/app/app_runtime.dart';
import 'package:sony_camera/domain/models/camera_file.dart';
import 'package:sony_camera/domain/models/transfer_job.dart';
import 'package:sony_camera/domain/models/transfer_progress.dart';
import 'package:sony_camera/domain/ports/camera_adapter.dart';
import 'package:sony_camera/platform/transfer_background.dart';

class RuntimeBackground extends TransferBackground {
  RuntimeBackground()
    : super(channel: const MethodChannel('test/runtime-background'));
  var starts = 0;
  var protected = false;
  @override
  Future<void> start({required int pendingFiles}) async {
    starts++;
    protected = true;
  }

  @override
  Future<void> stop() async {
    protected = false;
  }

  @override
  Future<void> update({
    required String filename,
    required int bytes,
    int? total,
  }) async {}
  @override
  Future<void> releaseNetwork() async {}
}

class RuntimeSource implements CameraAdapter {
  final bytes = List<int>.generate(4096, (i) => i % 256);
  var downloads = 0;
  @override
  Stream<TransferProgress> downloadOriginal(
    String id,
    String destination,
  ) async* {
    downloads++;
    await File(destination).writeAsBytes(bytes, flush: true);
    yield TransferProgress(
      bytesTransferred: bytes.length,
      totalBytes: bytes.length,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late RuntimeSource source;
  late RuntimeBackground background;
  late AppRuntime runtime;
  final file = CameraFile(
    id: '1:2',
    name: 'DSC_0001.ARW',
    extension: 'ARW',
    format: CameraFileFormat.raw,
    byteLength: 4096,
    thumbnailKey: 'source-v1',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('camera-runtime');
    source = RuntimeSource();
    background = RuntimeBackground();
    runtime = AppRuntime(
      supportDirectory: Directory('${root.path}/state'),
      cacheDirectory: Directory('${root.path}/cache'),
      importDirectory: Directory('${root.path}/imports'),
      background: background,
      resolveAdapter: (_) async => source,
    );
    await runtime.ready;
  });
  tearDown(() async {
    await runtime.close();
    await root.delete(recursive: true);
  });

  test(
    'real queue copies untouched bytes under the platform background lease',
    () async {
      await runtime.queue.add(
        cameraId: 'camera-1',
        files: [file],
        destination: runtime.importDirectory,
      );
      await runtime.resumeTransfers();
      for (
        var i = 0;
        i < 1000 && runtime.queue.jobs.first.state != TransferState.completed;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(runtime.queue.jobs.first.state, TransferState.completed);
      expect(
        await File(runtime.queue.jobs.first.destinationPath).readAsBytes(),
        source.bytes,
      );
      await runtime.queue.pause();
      expect(source.downloads, 1);
      expect(background.starts, 1);
      expect(background.protected, isFalse);
    },
  );

  test(
    'manual pause and client identity survive reopening; resume is not forced',
    () async {
      await runtime.queue.add(
        cameraId: 'camera-1',
        files: [file],
        destination: runtime.importDirectory,
      );
      await runtime.pauseTransfers();
      final before = jsonDecode(
        await File('${root.path}/state/runtime.json').readAsString(),
      ) as Map;
      await runtime.close();
      final nextBackground = RuntimeBackground();
      runtime = AppRuntime(
        supportDirectory: Directory('${root.path}/state'),
        cacheDirectory: Directory('${root.path}/cache'),
        importDirectory: Directory('${root.path}/imports'),
        background: nextBackground,
        resolveAdapter: (_) async => source,
      );
      await runtime.ready;
      runtime.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final after = jsonDecode(
        await File('${root.path}/state/runtime.json').readAsString(),
      ) as Map;
      expect(after['guid'], before['guid']);
      expect(runtime.queue.jobs, hasLength(1));
      expect(runtime.autoResume, isFalse);
      expect(nextBackground.starts, 0);
      expect(source.downloads, 0);
    },
  );
}
