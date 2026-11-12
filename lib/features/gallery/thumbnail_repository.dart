import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../domain/models/camera_file.dart';
import '../../domain/ports/camera_adapter.dart';
import '../../domain/ports/versioned_thumbnail_source.dart';
import '../../data/local/thumbnail_disk_cache.dart';

enum ThumbnailStatus { idle, queued, loading, ready, unavailable, error }

@immutable
final class ThumbnailState {
  const ThumbnailState({required this.status, this.bytes, this.error});

  final ThumbnailStatus status;
  final Uint8List? bytes;
  final Object? error;
}

typedef _ThumbnailKey = (String, String, String?, int, DateTime?);

final class _Request {
  _Request(this.key, this.file, {this.preview = false});

  final _ThumbnailKey key;
  final CameraFile file;
  final result = Completer<Uint8List?>();
  bool preview;
}

/// Schedules encoded thumbnails only, with preview > visible > prefetch priority.
///
/// The caller supplies the actual viewport and (at most) its next row; this class
/// never expands that list or downloads original media. Cache identity includes
/// namespace, id, thumbnailKey, byteLength and capturedAt. Create a new repository
/// when switching camera/card/session namespace.
///
/// [CameraAdapter] cannot cancel requests. Removed queued work returns to idle,
/// but running work continues to occupy a slot. Its result may warm the cache
/// silently if no longer observed; an older file version cannot replace a newer
/// version. Importing pauses queued prefetch and reduces concurrency to one;
/// already running requests are allowed to finish.
///
/// The LRU budget covers repository-owned encoded bytes, not Flutter's decoded
/// image cache, adapter buffers, or bytes retained by callers. Empty, missing,
/// oversized (>2 MiB or >total budget) thumbnails become unavailable. Failures
/// and unavailable results are remembered until [retry], preventing scroll-driven
/// retry loops. These small terminal records live until disposal.
///
/// Disk caching is opt-in: the adapter must supply a stable camera/storage/file
/// revision namespace. Disk failures degrade to memory and camera thumbnails.
class ThumbnailRepository extends ChangeNotifier {
  ThumbnailRepository({
    required this.adapter,
    required this.namespace,
    this.maxConcurrent = 2,
    this.maxMemoryBytes = 32 * 1024 * 1024,
    this.diskCache,
  }) {
    if (maxConcurrent != 1 && maxConcurrent != 2) {
      throw ArgumentError.value(
        maxConcurrent,
        'maxConcurrent',
        'Must be 1 or 2',
      );
    }
    if (maxMemoryBytes <= 0) {
      throw ArgumentError.value(
        maxMemoryBytes,
        'maxMemoryBytes',
        'Must be positive',
      );
    }
  }

  static const int maxEntryBytes = 2 * 1024 * 1024;
  static const _idle = ThumbnailState(status: ThumbnailStatus.idle);
  static const _queued = ThumbnailState(status: ThumbnailStatus.queued);
  static const _loading = ThumbnailState(status: ThumbnailStatus.loading);
  static const _unavailable = ThumbnailState(
    status: ThumbnailStatus.unavailable,
  );

  final CameraAdapter adapter;
  final String namespace;
  final int maxConcurrent;
  final int maxMemoryBytes;
  final ThumbnailDiskCache? diskCache;
  final _bypassDisk = <_ThumbnailKey>{};

  final _cache = <_ThumbnailKey, Uint8List>{};
  final _terminal = <_ThumbnailKey, ThumbnailState>{};
  final _queue = <_ThumbnailKey, _Request>{};
  final _inFlight = <_ThumbnailKey, _Request>{};
  Map<_ThumbnailKey, CameraFile> _visible = {};
  Map<_ThumbnailKey, CameraFile> _prefetch = {};
  int _memoryBytes = 0;
  bool _importActive = false;
  bool _disposed = false;
  bool _pumping = false;
  bool _notificationScheduled = false;
  bool _notifying = false;

  _ThumbnailKey _key(CameraFile file) =>
      (namespace, file.id, file.thumbnailKey, file.byteLength, file.capturedAt);

  /// Reads synchronously without requesting data. Cache hits refresh LRU order.
  /// Bytes are immutable, owned copies of the adapter's encoded thumbnail.
  ThumbnailState stateFor(CameraFile file) {
    if (_disposed) return _idle;
    final key = _key(file);
    final bytes = _cached(key);
    if (bytes != null) {
      return ThumbnailState(status: ThumbnailStatus.ready, bytes: bytes);
    }
    if (_inFlight.containsKey(key)) return _loading;
    if (_queue.containsKey(key)) return _queued;
    return _terminal[key] ?? _idle;
  }

  /// Replaces demand; queued non-preview work outside these lists is dropped.
  /// Identical keys are deduplicated, keeping caller order within each priority.
  void setViewport({
    required List<CameraFile> visible,
    List<CameraFile> prefetch = const [],
  }) {
    if (_disposed) return;
    _visible = {for (final file in visible) _key(file): file};
    _prefetch = {
      for (final file in prefetch)
        if (!_visible.containsKey(_key(file))) _key(file): file,
    };
    for (final request in _queue.values.toList()) {
      if (!request.preview && !_observed(request.key)) {
        _queue.remove(request.key);
        request.result.complete(null);
        _changed();
      }
    }
    for (final file in [..._visible.values, ..._prefetch.values]) {
      _enqueue(file);
    }
    _pump();
  }

  /// Shares cached, queued or running work and promotes it above viewport work.
  /// Returns null on unavailable/error/disposal; consult [stateFor] for details.
  /// A terminal failure is retried only by an explicit call to [retry].
  Future<Uint8List?> loadForPreview(CameraFile file) {
    if (_disposed) return Future.value(null);
    final key = _key(file);
    final bytes = _cached(key);
    if (bytes != null) return Future.value(bytes);
    if (_terminal.containsKey(key)) return Future.value(null);
    final request = _enqueue(file, preview: true)!;
    _pump();
    return request.result.future;
  }

  /// Explicit user retry, including bytes rejected later by the image decoder.
  /// Existing queued/running requests are reused, never duplicated.
  /// Offscreen retries are treated as preview-priority user requests.
  void retry(CameraFile file) {
    if (_disposed) return;
    final key = _key(file);
    final removed = _cache.remove(key);
    if (removed != null) _memoryBytes -= removed.lengthInBytes;
    _bypassDisk.add(key);
    unawaited(_removeDisk(key));
    _terminal.remove(key);
    _enqueue(file, preview: true);
    _pump();
  }

  String _diskKey(_ThumbnailKey key) =>
      jsonEncode([key.$1, key.$2, key.$3, key.$4, key.$5?.toIso8601String()]);

  Future<void> _removeDisk(_ThumbnailKey key) async {
    try {
      await diskCache?.remove(_diskKey(key));
    } catch (_) {
      // A cache is disposable; it must never block a fresh camera request.
    }
  }

  Future<void> clearCache() async {
    _cache.clear();
    _memoryBytes = 0;
    _terminal.clear();
    await diskCache?.clear();
    _changed();
  }

  void setImportActive(bool active) {
    if (_disposed || _importActive == active) return;
    _importActive = active;
    _pump();
  }

  bool _observed(_ThumbnailKey key) =>
      _visible.containsKey(key) || _prefetch.containsKey(key);

  Uint8List? _cached(_ThumbnailKey key) {
    final bytes = _cache.remove(key);
    if (bytes != null) _cache[key] = bytes;
    return bytes;
  }

  _Request? _enqueue(CameraFile file, {bool preview = false}) {
    final key = _key(file);
    if (_cache.containsKey(key) || _terminal.containsKey(key)) return null;
    final existing = _inFlight[key] ?? _queue[key];
    if (existing != null) {
      existing.preview |= preview;
      return existing;
    }
    final request = _Request(key, file, preview: preview);
    _queue[key] = request;
    _changed();
    return request;
  }

  _Request? _next() {
    for (final request in _queue.values) {
      if (request.preview) return request;
    }
    for (final key in _visible.keys) {
      final request = _queue[key];
      if (request != null) return request;
    }
    if (!_importActive) {
      for (final key in _prefetch.keys) {
        final request = _queue[key];
        if (request != null) return request;
      }
    }
    return null;
  }

  void _pump() {
    if (_disposed || _pumping) return;
    _pumping = true;
    try {
      final limit = _importActive ? 1 : maxConcurrent;
      while (!_disposed && _inFlight.length < limit) {
        final request = _next();
        if (request == null) break;
        _queue.remove(request.key);
        _inFlight[request.key] = request;
        _changed();
        unawaited(_load(request));
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _load(_Request request) async {
    Uint8List? bytes;
    try {
      Uint8List? cached;
      final bypass = _bypassDisk.remove(request.key);
      if (diskCache != null && !bypass) {
        try {
          cached = await diskCache?.read(_diskKey(request.key));
        } catch (_) {
          // Missing/corrupt/unwritable caches do not make the gallery unusable.
        }
      }
      if (_disposed) return;
      if (cached != null &&
          cached.isNotEmpty &&
          cached.lengthInBytes <= maxEntryBytes &&
          cached.lengthInBytes <= maxMemoryBytes) {
        bytes = cached.asUnmodifiableView();
        _store(request.key, bytes);
        return;
      }
      final source = adapter;
      final response = source is VersionedThumbnailSource
          ? await (source as VersionedThumbnailSource).loadVersionedThumbnail(
              request.file,
            )
          : await source.loadThumbnail(request.file.id);
      if (_disposed) return;
      if (response == null || response.isEmpty) {
        _terminal[request.key] = _unavailable;
      } else if (response.lengthInBytes > maxEntryBytes ||
          response.lengthInBytes > maxMemoryBytes) {
        _terminal[request.key] = ThumbnailState(
          status: ThumbnailStatus.unavailable,
          error: StateError(
            'Encoded thumbnail exceeds the memory admission limit',
          ),
        );
      } else {
        // A small view can otherwise retain a huge adapter buffer. The owned,
        // immutable copy also prevents callers from corrupting cached bytes.
        bytes = Uint8List.fromList(response).asUnmodifiableView();
        _store(request.key, bytes);
        if (diskCache != null) unawaited(_writeDisk(request.key, bytes));
      }
    } catch (error) {
      if (!_disposed) {
        _terminal[request.key] = ThumbnailState(
          status: ThumbnailStatus.error,
          error: error,
        );
      }
    } finally {
      if (!_disposed) {
        _inFlight.remove(request.key);
        if (!request.result.isCompleted) request.result.complete(bytes);
        if (request.preview || _observed(request.key)) _changed();
        _pump();
      }
    }
  }

  Future<void> _writeDisk(_ThumbnailKey key, Uint8List bytes) async {
    try {
      await diskCache?.write(_diskKey(key), bytes);
    } catch (_) {
      // This remains a ready memory thumbnail even if the disk is full.
    }
  }

  void _store(_ThumbnailKey key, Uint8List bytes) {
    while (_memoryBytes + bytes.lengthInBytes > maxMemoryBytes) {
      final oldest = _cache.keys.first;
      _memoryBytes -= _cache.remove(oldest)!.lengthInBytes;
      if (_observed(oldest)) _changed();
    }
    _cache[key] = bytes;
    _memoryBytes += bytes.lengthInBytes;
  }

  // Coalesce transitions and avoid notifying synchronously from layout/build.
  void _changed() {
    if (_disposed || _notificationScheduled) return;
    _notificationScheduled = true;
    scheduleMicrotask(() {
      _notificationScheduled = false;
      if (_disposed) return;
      _notifying = true;
      try {
        notifyListeners();
      } finally {
        _notifying = false;
        if (_disposed) super.dispose();
      }
    });
  }

  /// Settles preview waiters with null immediately. Late adapter successes and
  /// errors are consumed without cache mutation, notifications or further work.
  /// Calls after disposal are harmless (reads are idle, preview returns null).
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final request in [..._queue.values, ..._inFlight.values]) {
      if (!request.result.isCompleted) request.result.complete(null);
    }
    _queue.clear();
    _inFlight.clear();
    _cache.clear();
    _terminal.clear();
    _bypassDisk.clear();
    _visible.clear();
    _prefetch.clear();
    _memoryBytes = 0;
    // ChangeNotifier forbids super.dispose() during its listener iteration.
    if (!_notifying) super.dispose();
  }
}
