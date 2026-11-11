import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camport/app/app_runtime.dart';
import 'package:camport/app/camera_transfer_app.dart';
import 'package:camport/domain/models/camera_file.dart';
import 'package:camport/domain/models/transfer_job.dart';
import 'package:camport/domain/models/transfer_progress.dart';
import 'package:camport/domain/ports/camera_adapter.dart';
import 'package:camport/features/connection/connect_screen.dart';
import 'package:camport/features/import_queue/import_queue_screen.dart';
import 'package:camport/platform/transfer_background.dart';

class ScreenBackground extends TransferBackground {
  ScreenBackground()
    : super(channel: const MethodChannel('test/runtime-screens-background'));

  int preparations = 0;
  int settingsOpened = 0;
  int starts = 0;
  final disposed = Completer<void>();
  Completer<Map<String, Object?>>? pendingNetwork;

  @override
  Future<Map<String, Object?>> prepareNetwork() async {
    preparations++;
    return pendingNetwork?.future ??
        {'connected': false, 'message': '本地网络权限未允许，请在系统设置中允许后重试'};
  }

  @override
  Future<void> openWifiSettings() async => settingsOpened++;
  @override
  Future<void> start({required int pendingFiles}) async => starts++;
  @override
  Future<void> stop() async {}
  @override
  Future<void> releaseNetwork() async {}
  @override
  Future<void> update({
    required String filename,
    required int bytes,
    int? total,
  }) async {}
  @override
  Future<void> dispose() async {
    await super.dispose();
    if (!disposed.isCompleted) disposed.complete();
  }
}

enum SourceMode { fail, hold, complete }

class ScreenSource implements CameraAdapter {
  SourceMode mode = SourceMode.hold;
  int downloads = 0;
  final payload = List.generate(64, (i) => i);

  @override
  Stream<TransferProgress> downloadOriginal(String id, String destination) {
    downloads++;
    if (mode == SourceMode.fail) return Stream.error(StateError('测试来源暂不可用'));
    final controller = StreamController<TransferProgress>();
    var cancelled = false;
    controller.onCancel = () {
      cancelled = true;
    };
    controller.onListen = () {
      unawaited(
        () async {
          await File(destination).writeAsBytes(
            mode == SourceMode.hold ? payload.sublist(0, 16) : payload,
            flush: true,
          );
          if (cancelled) return;
          controller.add(
            TransferProgress(
              bytesTransferred: mode == SourceMode.hold ? 16 : 64,
              totalBytes: 64,
            ),
          );
          if (mode != SourceMode.hold) await controller.close();
        }().catchError((Object error, StackTrace stack) {
          if (!cancelled) controller.addError(error, stack);
        }),
      );
    };
    return controller.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ScreenBackground background;
  late ScreenSource source;
  late AppRuntime runtime;
  const file = CameraFile(
    id: '1:2',
    name: 'DSC_0001.ARW',
    extension: 'ARW',
    format: CameraFileFormat.raw,
    byteLength: 64,
    thumbnailKey: 'source-v1',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('runtime-screens-');
    background = ScreenBackground();
    source = ScreenSource();
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
    await background.disposed.future;
    await root.delete(recursive: true);
  });

  Future<void> addJob(WidgetTester tester) async {
    await tester.runAsync(
      () => runtime.queue.add(
        cameraId: 'camera-1',
        files: [file],
        destination: runtime.importDirectory,
      ),
    );
  }

  Future<void> waitFor(WidgetTester tester, bool Function() predicate) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 500 && !predicate(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(predicate(), isTrue);
    });
    await tester.pump();
  }

  testWidgets(
    'startup failure can retry and the app owns only its opened runtime',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        CameraTransferApp(
          runtimeFactory: () async {
            if (++attempts == 1) throw const FileSystemException('测试初始化失败');
            return runtime;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('初始化失败'), findsWidgets);
      await tester.tap(find.text('重试初始化'));
      await tester.pumpAndSettle();
      expect(find.text('连接相机'), findsOneWidget);
      expect(find.text('导入队列'), findsOneWidget);
      expect(attempts, 2);
      expect(background.disposed.isCompleted, isFalse);
      await tester.pumpWidget(const SizedBox());
      await waitFor(tester, () => background.disposed.isCompleted);
    },
  );

  testWidgets(
    'manual form rejects public IP and invalid port before network work',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ConnectScreen(runtime: runtime)),
      );
      final submit = find.byKey(const Key('manual-connect'));
      await tester.ensureVisible(submit);
      await tester.enterText(find.byKey(const Key('camera-host')), '8.8.8.8');
      await tester.enterText(find.byKey(const Key('camera-port')), '70000');
      await tester.tap(submit);
      await tester.pump();
      expect(find.textContaining('局域网 IPv4'), findsWidgets);
      expect(find.textContaining('1–65535'), findsOneWidget);
      expect(background.preparations, 0);
      await tester.enterText(
        find.byKey(const Key('camera-host')),
        '192.168.122.1',
      );
      await tester.enterText(find.byKey(const Key('camera-port')), '15740');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(background.preparations, 1);
      expect(find.textContaining('本地网络权限未允许'), findsOneWidget);
      expect(source.downloads, 0);
    },
  );

  testWidgets(
    'Wi-Fi settings use injected service and duplicate connection taps are disabled',
    (tester) async {
      background.pendingNetwork = Completer<Map<String, Object?>>();
      await tester.pumpWidget(
        MaterialApp(home: ConnectScreen(runtime: runtime)),
      );
      await tester.tap(find.text('打开 Wi-Fi 设置'));
      await tester.pumpAndSettle();
      expect(background.settingsOpened, 1);
      await tester.enterText(
        find.byKey(const Key('camera-host')),
        '192.168.122.1',
      );
      final submit = find.byKey(const Key('manual-connect'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pump();
      await tester.tap(submit);
      await tester.pump();
      expect(background.preparations, 1);
      background.pendingNetwork!.complete({
        'connected': false,
        'message': '请先加入 DIRECT 相机 Wi-Fi',
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('请先加入 DIRECT'), findsOneWidget);
    },
  );

  testWidgets('queue continue, pause, and cancel mutate the durable queue', (
    tester,
  ) async {
    await addJob(tester);
    await tester.pumpWidget(
      MaterialApp(home: ImportQueueScreen(runtime: runtime)),
    );
    expect(find.text('待导入'), findsOneWidget);
    await tester.tap(find.text('继续'));
    await waitFor(
      tester,
      () => runtime.queue.jobs.first.bytesTransferred == 16,
    );
    expect(runtime.queue.isRunning, isTrue);
    await tester.tap(find.text('暂停'));
    await waitFor(tester, () => !runtime.queue.isRunning);
    expect(runtime.autoResume, isFalse);
    expect(runtime.queue.jobs.first.state, TransferState.interrupted);
    await tester.tap(find.byKey(Key('cancel-${runtime.queue.jobs.first.id}')));
    await waitFor(
      tester,
      () => runtime.queue.jobs.first.state == TransferState.cancelled,
    );
    expect(find.text('已取消'), findsOneWidget);
    expect(
      await tester.runAsync(
        () => File(runtime.queue.jobs.first.temporaryPath!).exists(),
      ),
      isTrue,
    );
    expect(background.starts, 1);
  });

  testWidgets(
    'failed job retry performs a real local copy and exposes local checksum',
    (tester) async {
      source.mode = SourceMode.fail;
      await addJob(tester);
      await tester.pumpWidget(
        MaterialApp(home: ImportQueueScreen(runtime: runtime)),
      );
      await tester.tap(find.text('继续'));
      await waitFor(
        tester,
        () =>
            runtime.queue.jobs.first.state == TransferState.failed &&
            !runtime.queue.isRunning,
      );
      expect(find.textContaining('测试来源暂不可用'), findsOneWidget);
      source.mode = SourceMode.complete;
      await tester.tap(find.byKey(Key('retry-${runtime.queue.jobs.first.id}')));
      await waitFor(
        tester,
        () =>
            runtime.queue.jobs.first.state == TransferState.completed &&
            !runtime.queue.isRunning,
      );
      expect(source.downloads, 2);
      final job = runtime.queue.jobs.first;
      await tester.tap(find.text('DSC_0001.ARW'));
      await tester.pumpAndSettle();
      expect(find.text('本机 SHA-256'), findsOneWidget);
      expect(find.text(job.checksum!), findsOneWidget);
      expect(find.text(job.destinationPath), findsOneWidget);
      expect(
        await tester.runAsync(() => File(job.destinationPath).readAsBytes()),
        source.payload,
      );
    },
  );

  testWidgets('sample gallery stays separate and never creates import jobs', (
    tester,
  ) async {
    await tester.pumpWidget(
      CameraTransferApp(runtimeFactory: () async => runtime),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看示例图库（不会导入）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('示例'), findsWidgets);
    expect(runtime.queue.jobs, isEmpty);
    expect(source.downloads, 0);
    expect(background.preparations, 0);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(background.disposed.isCompleted, isFalse);
    await tester.tap(find.text('导入队列'));
    await tester.pumpAndSettle();
    expect(find.text('暂无导入任务'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await waitFor(tester, () => background.disposed.isCompleted);
  });
}
