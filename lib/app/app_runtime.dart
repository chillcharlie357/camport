import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../data/local/thumbnail_disk_cache.dart';
import '../data/adapters/camera_session_factory.dart';
import '../domain/models/camera_capabilities.dart';
import '../domain/models/camera_file.dart';
import '../domain/models/camera_page.dart';
import '../domain/models/camera_profile.dart';
import '../domain/models/transfer_job.dart';
import '../domain/models/transfer_progress.dart';
import '../domain/ports/camera_adapter.dart';
import '../domain/ports/camera_session.dart';
import '../domain/ports/versioned_thumbnail_source.dart';
import '../features/import_queue/transfer_queue.dart';
import '../platform/transfer_background.dart';

/// One app/engine owner for sessions and work that outlives gallery routes.
class AppRuntime extends ChangeNotifier with WidgetsBindingObserver {
  AppRuntime({
    required this.supportDirectory,
    required this.cacheDirectory,
    required this.importDirectory,
    TransferBackground? background,
    CameraSessionRegistry? sessionRegistry,
    Future<CameraAdapter> Function(TransferJob)? resolveAdapter,
  }) : sessionRegistry =
           sessionRegistry ??
           CameraSessionRegistry([const SonyPtpSessionFactory()]),
       background = background ?? TransferBackground() {
    cache = ThumbnailDiskCache(
      directory: Directory('${cacheDirectory.path}/thumbnails-v1'),
    );
    queue = TransferQueue(
      directory: Directory('${supportDirectory.path}/queue-v1'),
      resolveAdapter: resolveAdapter ?? _resolveJob,
      onStart: (count) => this.background.start(pendingFiles: count),
      onStop: () => this.background.stop(),
      onProgress: _progress,
    );
    queue.addListener(_queueChanged);
    _events = this.background.events.listen(_backgroundEvent);
    WidgetsBinding.instance.addObserver(this);
    ready = _initialize();
  }

  static Future<AppRuntime> open() async {
    final runtime = AppRuntime(
      supportDirectory: await getApplicationSupportDirectory(),
      cacheDirectory: await getApplicationCacheDirectory(),
      importDirectory: Directory(
        '${(await getApplicationDocumentsDirectory()).path}/Sony Imports',
      ),
    );
    try {
      await runtime.ready;
      if (runtime._autoResume &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        runtime._launchQueue();
      }
      return runtime;
    } catch (_) {
      await runtime.close();
      rethrow;
    }
  }

  final Directory supportDirectory;
  final Directory cacheDirectory;
  final Directory importDirectory;
  final TransferBackground background;
  final CameraSessionRegistry sessionRegistry;
  late final ThumbnailDiskCache cache;
  late final TransferQueue queue;
  late final Future<void> ready;
  late final StreamSubscription<BackgroundTransferEvent> _events;
  final _profiles = <String, CameraProfile>{};
  final _proxies = <String, _SessionAdapter>{};
  Uint8List _guid = Uint8List(16);
  CameraSession? _adapter;
  CameraSession? _opening;
  Future<CameraProfile>? _connecting;
  Future<void> _writes = Future.value();
  String? _lastProfileId;
  int _generation = 0;
  int connectionEpoch = 0;
  bool _closed = false;
  bool _autoResume = false;
  bool _lifecyclePaused = false;
  Future<void>? _lifecyclePause;
  bool discovering = false;
  Object? error;
  String? networkMessage;
  List<CameraProfile> endpoints = const [];
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);

  bool get connecting => _connecting != null;
  bool get connected => _adapter?.connected == true;
  CameraProfile? get profile => _adapter?.profile;
  CameraProfile? get lastProfile => _profiles[_lastProfileId];
  List<CameraProfile> get savedProfiles => List.unmodifiable(_profiles.values);
  String? get thumbnailNamespace => _adapter?.cacheNamespace;
  bool get autoResume => _autoResume;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  File get _settings => File('${supportDirectory.path}/runtime.json');

  Future<void> _initialize() async {
    await supportDirectory.create(recursive: true);
    await importDirectory.create(recursive: true);
    if (await _settings.exists()) {
      if (await _settings.length() > 1024 * 1024) {
        throw const FormatException('连接记录过大');
      }
      final data =
          jsonDecode(await _settings.readAsString()) as Map<String, dynamic>;
      final rawGuid = base64Decode(data['guid'] as String);
      if (rawGuid.length != 16) throw const FormatException('无效的相机客户端标识');
      _guid = rawGuid;
      _autoResume = data['autoResume'] == true;
      _lastProfileId = data['lastProfileId'] as String?;
      for (final raw in data['profiles'] as List<dynamic>) {
        final item = raw as Map<String, dynamic>;
        final config = Map<String, String>.from(item['config'] as Map);
        final p = CameraProfile(
          id: item['id'] as String,
          displayName: item['name'] as String,
          model: item['model'] as String?,
          firmware: item['firmware'] as String?,
          connectionKind: ConnectionKind.values.byName(
            item['connectionKind'] as String? ?? 'cameraAccessPoint',
          ),
          connectionConfiguration: config,
        );
        sessionRegistry.validateSavedProfile(p);
        _profiles[p.id] = p;
      }
    } else {
      final random = Random.secure();
      _guid = Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
      await _persist();
    }
    await queue.ready;
    // A disposable cache cannot stop a durable import queue from opening.
    try {
      await cache.ready;
    } catch (_) {
      /* Requests fall back to camera. */
    }
  }

  Future<void> _persist() {
    final snapshot = jsonEncode({
      'version': 1,
      'guid': base64Encode(_guid),
      'autoResume': _autoResume,
      'lastProfileId': _lastProfileId,
      'profiles': _profiles.values
          .map(
            (p) => {
              'id': p.id,
              'name': p.displayName,
              'model': p.model,
              'firmware': p.firmware,
              'connectionKind': p.connectionKind.name,
              'config': p.connectionConfiguration,
            },
          )
          .toList(),
    });
    final operation = _writes.then((_) async {
      final part = File('${_settings.path}.part');
      await part.writeAsString(snapshot, flush: true);
      await part.rename(_settings.path);
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  /// Forget a saved endpoint only when no unfinished transfer depends on it.
  Future<void> forgetProfile(String profileId) async {
    if (connected && profile?.id == profileId ||
        connecting ||
        queue.jobs.any(
          (job) =>
              job.cameraId == profileId &&
              job.state != TransferState.completed &&
              job.state != TransferState.cancelled,
        )) {
      throw StateError('该相机正在使用或仍有未完成的导入任务，请先完成或取消任务');
    }
    final old = _profiles.remove(profileId);
    if (old == null) return;
    final previousLast = _lastProfileId;
    if (_lastProfileId == profileId) _lastProfileId = null;
    try {
      await _persist();
      _notify();
    } catch (_) {
      _profiles[profileId] = old;
      _lastProfileId = previousLast;
      _notify();
      rethrow;
    }
  }

  Future<void> search() async {
    if (discovering || connecting || queue.isRunning) return;
    discovering = true;
    error = null;
    endpoints = const [];
    _notify();
    try {
      final network = await background.prepareNetwork().timeout(
        const Duration(seconds: 15),
      );
      networkMessage = network['message'] as String?;
      if (network['connected'] != true) {
        throw StateError(networkMessage ?? '请先连接相机 Wi-Fi');
      }
      endpoints = await sessionRegistry.discover();
      if (endpoints.isEmpty) {
        error = StateError('没有发现相机；请确认智能手机连接模式，或手动输入相机 IP');
      }
    } catch (e) {
      error = e;
    } finally {
      discovering = false;
      if (!connected && !queue.isRunning && !connecting) {
        try {
          await background.releaseNetwork();
        } catch (failure) {
          error ??= failure;
        }
      }
      _notify();
    }
  }

  Future<CameraProfile> connectProfile(CameraProfile target) =>
      _connectProfile(target, forTransfer: false);

  Future<CameraProfile> _connectProfile(
    CameraProfile target, {
    required bool forTransfer,
  }) {
    if (_closed) return Future.error(StateError('应用会话已关闭'));
    if (queue.isRunning &&
        !forTransfer &&
        !(connected && profile?.id == target.id)) {
      return Future.error(StateError('正在导入原片，请先暂停导入队列再切换相机'));
    }
    final existing = _connecting;
    if (existing != null) {
      return existing.then(
        (_) => _connectProfile(target, forTransfer: forTransfer),
      );
    }
    if (connected && profile?.id == target.id) return Future.value(profile!);
    final generation = ++_generation;
    final operation = _connect(target, generation, forTransfer: forTransfer)
        .catchError((Object failure, StackTrace stack) async {
          // A failed explicit connection should not retain a process-wide
          // camera Wi-Fi binding. The queue owns its network lease while it
          // is running, and cancellation has its own cleanup path.
          if (!_closed &&
              generation == _generation &&
              !queue.isRunning &&
              !connected) {
            try {
              await background.releaseNetwork();
            } catch (_) {
              // Preserve the original connection error for the UI.
            }
          }
          Error.throwWithStackTrace(failure, stack);
        });
    _connecting = operation;
    _notify();
    return operation.whenComplete(() {
      if (identical(_connecting, operation)) {
        _connecting = null;
        _notify();
      }
    });
  }

  Future<CameraProfile> _connect(
    CameraProfile target,
    int generation, {
    required bool forTransfer,
  }) async {
    error = null;
    final network = await background.prepareNetwork().timeout(
      const Duration(seconds: 15),
    );
    if (_closed || generation != _generation) throw StateError('连接已取消');
    networkMessage = network['message'] as String?;
    if (network['connected'] != true) {
      throw StateError(networkMessage ?? '请先连接相机 Wi-Fi');
    }
    if (queue.isRunning &&
        !forTransfer &&
        !(connected && profile?.id == target.id)) {
      throw StateError('正在导入原片，请先暂停导入队列再切换相机');
    }
    await _adapter?.close();
    if (_closed || generation != _generation) throw StateError('连接已取消');
    _adapter = null;
    final adapter = sessionRegistry.create(target, _guid);
    _opening = adapter;
    CameraProfile? previousProfile;
    final previousLastId = _lastProfileId;
    try {
      final result = await adapter.connect(target);
      if (sessionRegistry.adapterId(result) !=
          sessionRegistry.adapterId(target)) {
        throw StateError('相机适配器标识发生变化，请重新连接');
      }
      if (_closed || generation != _generation) throw StateError('连接已取消');
      previousProfile = _profiles[result.id];
      _profiles[result.id] = result;
      _lastProfileId = result.id;
      try {
        await _persist();
      } catch (_) {
        if (previousProfile == null) {
          _profiles.remove(result.id);
        } else {
          _profiles[result.id] = previousProfile;
        }
        _lastProfileId = previousLastId;
        rethrow;
      }
      if (_closed || generation != _generation) throw StateError('连接已取消');
      _adapter = adapter;
      _opening = null;
      connectionEpoch++;
      _notify();
      return result;
    } catch (e) {
      await adapter.close();
      if (identical(_adapter, adapter)) _adapter = null;
      if (identical(_opening, adapter)) _opening = null;
      if (generation == _generation) {
        error = e;
        _notify();
      }
      rethrow;
    }
  }

  Future<CameraSession> _ensureCamera(
    String cameraId, {
    bool forTransfer = false,
  }) async {
    if (connected && profile?.id == cameraId) return _adapter!;
    final saved = _profiles[cameraId];
    if (saved == null) throw StateError('找不到此相机的连接记录，请重新连接并选择文件');
    await _connectProfile(saved, forTransfer: forTransfer);
    if (profile?.id != cameraId) throw StateError('相机身份已变化，未开始原片传输');
    return _adapter!;
  }

  Future<CameraAdapter> _resolveJob(TransferJob job) async {
    final adapter = await _ensureCamera(job.cameraId, forTransfer: true);
    adapter.expectFile(
      job.cameraFileId,
      sourceVersion: job.sourceVersion,
      byteLength: job.totalBytes,
    );
    return adapter;
  }

  CameraAdapter galleryAdapter(String cameraId) =>
      _proxies.putIfAbsent(cameraId, () => _SessionAdapter(this, cameraId));

  Future<void> importFiles(String cameraId, List<CameraFile> files) async {
    if (files.isEmpty) return;
    await queue.add(
      cameraId: cameraId,
      files: files,
      destination: importDirectory,
    );
    try {
      await resumeTransfers();
    } catch (failure) {
      // The queue entry is already durable. Keep it visible for a manual
      // retry instead of telling the caller that the import was not queued.
      error = failure;
      _notify();
    }
  }

  Future<void> resumeTransfers() async {
    _autoResume = true;
    _lifecyclePaused = false;
    error = null;
    _notify();
    try {
      await _persist();
    } catch (failure) {
      error = failure;
      _notify();
      rethrow;
    }
    _launchQueue();
  }

  void _launchQueue() {
    if (_closed) return;
    unawaited(
      queue.start().catchError((Object e) {
        error = e;
        _notify();
      }),
    );
  }

  Future<void> pauseTransfers() async {
    _autoResume = false;
    _lifecyclePaused = false;
    await _persist();
    ++_generation;
    await _opening?.close();
    _opening = null;
    await queue.pause();
    _notify();
  }

  Future<void> _progress(TransferJob job) async {
    final now = DateTime.now();
    if (now.difference(_lastProgress).inMilliseconds < 500 &&
        job.bytesTransferred != job.totalBytes) {
      return;
    }
    _lastProgress = now;
    await background.update(
      filename: job.fileName,
      bytes: job.bytesTransferred,
      total: job.totalBytes,
    );
  }

  void _queueChanged() {
    _notify();
  }

  void _backgroundEvent(BackgroundTransferEvent event) {
    if (_closed) return;
    if (event == BackgroundTransferEvent.resumeRequested) {
      if (_autoResume && _lifecyclePaused) {
        unawaited(_resumeAfterLifecyclePause());
      }
      return;
    }
    if (event == BackgroundTransferEvent.pauseRequested) {
      unawaited(
        pauseTransfers().catchError((Object e) {
          error = e;
          _notify();
        }),
      );
    } else if (queue.isRunning) {
      _lifecyclePaused = _autoResume;
      _lifecyclePause ??=
          (() async {
            ++_generation;
            await _opening?.close();
            _opening = null;
            await queue.pause();
          })().catchError((Object e) {
            error = e;
            _notify();
          });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _autoResume) {
      unawaited(_resumeAfterLifecyclePause());
    }
  }

  Future<void> _resumeAfterLifecyclePause() async {
    await _lifecyclePause;
    _lifecyclePause = null;
    if (!_closed && _autoResume) {
      _lifecyclePaused = false;
      _launchQueue();
    }
  }

  Future<void> cancelConnection() async {
    if (_connecting == null) return;
    ++_generation;
    final pending = _connecting;
    Object? cleanupError;
    try {
      await _opening?.close();
      // Release also cancels a platform permission/network request in progress.
      // Do this before awaiting the Dart connection so cancellation is prompt.
      if (!connected && !queue.isRunning) await background.releaseNetwork();
    } catch (failure) {
      cleanupError = failure;
    }
    try {
      await pending;
    } catch (_) {
      // The caller of connectProfile receives the cancellation error.
    }
    _opening = null;
    _notify();
    if (cleanupError != null) throw cleanupError;
  }

  Future<void> disconnect() async {
    ++_generation;
    _connecting = null;
    await pauseTransfers();
    await _opening?.close();
    _opening = null;
    await _adapter?.close();
    _adapter = null;
    await background.releaseNetwork();
    _notify();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    await _events.cancel();
    queue.removeListener(_queueChanged);
    await queue.close();
    await _opening?.close();
    await _adapter?.close();
    try {
      await background.stop();
      await background.releaseNetwork();
    } catch (_) {
      /* Native process cleanup is idempotent. */
    }
    try {
      await cache.close();
    } catch (_) {
      /* Disposable cache failure. */
    }
    await _writes;
    await background.dispose();
    super.dispose();
  }
}

class _SessionAdapter implements CameraAdapter, VersionedThumbnailSource {
  _SessionAdapter(this.runtime, this.cameraId);
  final AppRuntime runtime;
  final String cameraId;
  int _listedEpoch = -1;
  final _versions = <String, String?>{};

  @override
  Future<CameraProfile> connect(CameraProfile profile) =>
      runtime.connectProfile(profile);
  @override
  Future<CameraCapabilities> discoverCapabilities() async =>
      (await runtime._ensureCamera(cameraId)).discoverCapabilities();
  @override
  Future<CameraPage<CameraFile>> listFiles({String? cursor}) async {
    final adapter = await runtime._ensureCamera(cameraId);
    if (cursor != null && _listedEpoch != runtime.connectionEpoch) {
      throw StateError('相机会话已变化，请重新载入图库');
    }
    final epoch = runtime.connectionEpoch;
    final page = await adapter.listFiles(cursor: cursor);
    if (epoch != runtime.connectionEpoch) throw StateError('相机会话已变化，请重试');
    if (cursor == null) _versions.clear();
    for (final file in page.items) {
      _versions[file.id] = file.thumbnailKey;
    }
    _listedEpoch = epoch;
    return page;
  }

  @override
  Future<Uint8List?> loadThumbnail(String fileId) async =>
      (await runtime._ensureCamera(cameraId)).loadThumbnail(fileId);
  @override
  Future<Uint8List?> loadVersionedThumbnail(CameraFile file) async {
    final adapter = await runtime._ensureCamera(cameraId);
    if (_listedEpoch != runtime.connectionEpoch ||
        !_versions.containsKey(file.id) ||
        _versions[file.id] != file.thumbnailKey) {
      throw StateError('文件版本已变化，请重新载入图库');
    }
    return adapter.loadThumbnail(file.id);
  }

  @override
  Stream<TransferProgress> downloadOriginal(
    String fileId,
    String destinationPath,
  ) =>
      Stream.fromFuture(runtime._ensureCamera(cameraId))
          .asyncExpand((a) => a.downloadOriginal(fileId, destinationPath));
}
