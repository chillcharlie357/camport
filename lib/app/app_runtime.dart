import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../data/local/thumbnail_disk_cache.dart';
import '../data/sony/sony_discovery.dart';
import '../data/sony/sony_ptp_adapter.dart';
import '../domain/models/camera_capabilities.dart';
import '../domain/models/camera_file.dart';
import '../domain/models/camera_page.dart';
import '../domain/models/camera_profile.dart';
import '../domain/models/transfer_job.dart';
import '../domain/models/transfer_progress.dart';
import '../domain/ports/camera_adapter.dart';
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
    SonyCameraDiscovery? discovery,
    Future<CameraAdapter> Function(TransferJob)? resolveAdapter,
  }) : background = background ?? TransferBackground(),
       discovery = discovery ?? SonyCameraDiscovery() {
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
  final SonyCameraDiscovery discovery;
  late final ThumbnailDiskCache cache;
  late final TransferQueue queue;
  late final Future<void> ready;
  late final StreamSubscription<BackgroundTransferEvent> _events;
  final _profiles = <String, CameraProfile>{};
  final _proxies = <String, _SessionAdapter>{};
  Uint8List _guid = Uint8List(16);
  SonyPtpCameraAdapter? _adapter;
  SonyPtpCameraAdapter? _opening;
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
  List<SonyCameraEndpoint> endpoints = const [];
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
        SonyCameraEndpoint.manual(
          config['host']!,
          port: int.parse(config['port'] ?? '15740'),
        );
        final p = CameraProfile(
          id: item['id'] as String,
          displayName: item['name'] as String,
          model: item['model'] as String?,
          firmware: item['firmware'] as String?,
          connectionKind: ConnectionKind.cameraAccessPoint,
          connectionConfiguration: config,
        );
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

  Future<void> search() async {
    await ready;
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
      endpoints = await discovery.discover();
      if (endpoints.isEmpty) {
        error = StateError('没有发现相机；请确认智能手机连接模式，或手动输入相机 IP');
      }
    } catch (e) {
      error = e;
    } finally {
      discovering = false;
      _notify();
    }
  }

  Future<CameraProfile> connectProfile(CameraProfile target) {
    final existing = _connecting;
    if (existing != null) return existing.then((_) => connectProfile(target));
    if (connected && profile?.id == target.id) return Future.value(profile!);
    final generation = ++_generation;
    final operation = _connect(target, generation);
    _connecting = operation;
    _notify();
    return operation.whenComplete(() {
      if (identical(_connecting, operation)) {
        _connecting = null;
        _notify();
      }
    });
  }

  Future<CameraProfile> _connect(CameraProfile target, int generation) async {
    await ready;
    error = null;
    final network = await background.prepareNetwork().timeout(
      const Duration(seconds: 15),
    );
    if (_closed || generation != _generation) throw StateError('连接已取消');
    networkMessage = network['message'] as String?;
    if (network['connected'] != true) {
      throw StateError(networkMessage ?? '请先连接相机 Wi-Fi');
    }
    await _adapter?.close();
    final adapter = SonyPtpCameraAdapter(guid: _guid);
    _opening = adapter;
    try {
      final result = await adapter.connect(target);
      if (_closed || generation != _generation) throw StateError('连接已取消');
      _adapter = adapter;
      _opening = null;
      _profiles[result.id] = result;
      _lastProfileId = result.id;
      connectionEpoch++;
      await _persist();
      _notify();
      return result;
    } catch (e) {
      await adapter.close();
      if (identical(_opening, adapter)) _opening = null;
      if (generation == _generation) {
        error = e;
        _notify();
      }
      rethrow;
    }
  }

  Future<SonyPtpCameraAdapter> _ensureCamera(String cameraId) async {
    await ready;
    if (connected && profile?.id == cameraId) return _adapter!;
    final saved = _profiles[cameraId];
    if (saved == null) throw StateError('找不到此相机的连接记录，请重新连接并选择文件');
    await connectProfile(saved);
    if (profile?.id != cameraId) throw StateError('相机身份已变化，未开始原片传输');
    return _adapter!;
  }

  Future<CameraAdapter> _resolveJob(TransferJob job) async {
    final adapter = await _ensureCamera(job.cameraId);
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
    await ready;
    if (files.isEmpty) return;
    await queue.add(
      cameraId: cameraId,
      files: files,
      destination: importDirectory,
    );
    await resumeTransfers();
  }

  Future<void> resumeTransfers() async {
    await ready;
    _autoResume = true;
    _lifecyclePaused = false;
    error = null;
    await _persist();
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
