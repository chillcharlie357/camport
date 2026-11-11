import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A disposable, process-local disk LRU for encoded thumbnails only.
///
/// Give each instance an exclusively owned, private directory. Multiple active
/// instances/processes must not share it. The byte budget includes cache blobs,
/// the index, and transaction files (logical lengths, not filesystem blocks).
/// Reserving transaction space can evict entries before the budget is full.
/// Unknown files/directories are never removed or read as thumbnails.
///
/// All filesystem work is asynchronous; content hashing runs in a worker
/// isolate. Read touches are coalesced for 250 ms and flushed by [close]. Writes
/// atomically replace the index and retain a recoverable old blob until commit.
/// This is a cache, not durable storage: power loss can discard recent entries.
class ThumbnailDiskCache {
  ThumbnailDiskCache({
    required Directory directory,
    this.maxBytes = 256 * 1024 * 1024,
    this.maxEntryBytes = 2 * 1024 * 1024,
    this.maxAge = const Duration(days: 7),
    DateTime Function()? now,
  }) : _directory = _normalizedDirectory(directory),
       _now = now ?? DateTime.now {
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    if (maxEntryBytes <= 0) {
      throw ArgumentError.value(maxEntryBytes, 'maxEntryBytes');
    }
    if (maxAge <= Duration.zero) throw ArgumentError.value(maxAge, 'maxAge');
    ready = _enqueue(_initialize);
  }

  final int maxBytes;
  final int maxEntryBytes;
  final Duration maxAge;
  final DateTime Function() _now;
  Directory _directory;
  late final Future<void> ready;
  final _entries = <String, _DiskEntry>{};
  Future<void> _tail = Future.value();
  Future<void>? _closeFuture;
  Timer? _touchTimer;
  bool _closing = false;
  bool _initialized = false;
  bool _dirty = false;

  static final _hashPattern = RegExp(r'^[0-9a-f]{64}$');
  static final _ownedPattern = RegExp(r'^[0-9a-f]{64}(?:\.part|\.bak)?$');
  static const _indexName = 'index.json';
  static const _maxIndexBytes = 16 * 1024 * 1024;

  File _file(String name) =>
      File('${_directory.path}${Platform.pathSeparator}$name');
  String _key(String key) => sha256.convert(utf8.encode(key)).toString();

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    // A failed operation must not poison subsequent work or leak an unhandled
    // error when callers choose not to await public initialization immediately.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<T> _run<T>(Future<T> Function() action) => _enqueue(() async {
    await ready;
    return action();
  });

  Future<Uint8List?> read(String key) {
    if (_closing) return Future.value(null);
    final hashed = _key(key);
    return _run(() async {
      try {
        await _checkRoot();
        final entry = _entries[hashed];
        if (entry == null) return null;
        if (_expired(entry)) {
          await _discard(hashed);
          _scheduleTouch();
          return null;
        }
        await _recoverBackup(entry);
        final data = await _readEntry(_file(hashed), entry);
        if (data == null) {
          await _discard(hashed);
          _scheduleTouch();
          return null;
        }
        _entries.remove(hashed);
        _entries[hashed] = entry;
        _dirty = true;
        _scheduleTouch();
        return data;
      } on FileSystemException {
        return null;
      }
    });
  }

  /// Empty/oversized/unadmittable thumbnails are ignored, preserving old bytes.
  /// Filesystem failures are reported to the caller; they do not poison the LRU.
  Future<void> write(String key, Uint8List bytes) {
    if (_closing) {
      return Future.error(StateError('Thumbnail disk cache is closed'));
    }
    if (bytes.isEmpty ||
        bytes.length > maxEntryBytes ||
        bytes.length > maxBytes) {
      return Future.value();
    }
    // Take ownership before the first await, including for queued writes.
    final owned = Uint8List.fromList(bytes);
    final hashed = _key(key);
    return _run(() => _write(hashed, owned));
  }

  Future<void> _write(String hashed, Uint8List bytes) async {
    await _checkRoot();
    await _sweep();
    for (final entry in _entries.values.toList()) {
      if (_expired(entry)) await _discard(entry.key);
    }
    final previous = _entries[hashed];
    if (previous != null) await _recoverBackup(previous);
    final next = _DiskEntry(
      key: hashed,
      size: bytes.length,
      writtenAt: _now().millisecondsSinceEpoch,
      checksum: await _checksum(bytes),
    );
    final part = _file('$hashed.part');
    final backup = _file('$hashed.bak');
    final target = _file(hashed);
    await _prepareFresh(part);
    await _prepareFresh(backup);
    if (!await _makeRoom(next)) return;
    if (_dirty) await _persistIndex();

    final before = Map<String, _DiskEntry>.of(_entries);
    var movedOld = false;
    var installedNew = false;
    var committed = false;
    try {
      await part.writeAsBytes(bytes, flush: true);
      final type = await FileSystemEntity.type(target.path, followLinks: false);
      if (previous != null && type == FileSystemEntityType.file) {
        await target.rename(backup.path);
        movedOld = true;
      } else {
        await _prepareFresh(target);
      }
      await part.rename(target.path);
      installedNew = true;
      _entries.remove(hashed);
      _entries[hashed] = next;
      _dirty = true;
      await _persistIndex();
      committed = true;
    } catch (_) {
      _entries
        ..clear()
        ..addAll(before);
      _dirty = false; // The on-disk index still describes this snapshot.
      if (installedNew) await _deleteOwned(target);
      if (movedOld) await backup.rename(target.path);
      rethrow;
    } finally {
      // Cleanup failure after commit must not turn a successful replacement
      // into a reported failed write. Leftovers remain charged to the budget
      // and are recovered/swept on the next operation or startup.
      await _bestEffortDelete(part);
      if (committed) await _bestEffortDelete(backup);
    }
  }

  Future<void> remove(String key) {
    if (_closing) {
      return Future.error(StateError('Thumbnail disk cache is closed'));
    }
    final hashed = _key(key);
    return _run(() async {
      await _checkRoot();
      await _discard(hashed);
      await _persistIndex();
    });
  }

  /// Removes only this cache's flat filenames, never traversing directories.
  Future<void> clear() {
    if (_closing) {
      return Future.error(StateError('Thumbnail disk cache is closed'));
    }
    return _run(() async {
      await _checkRoot();
      _touchTimer?.cancel();
      _touchTimer = null;
      _entries.clear();
      _dirty = true;
      await _sweep();
      await _persistIndex();
    });
  }

  /// Drains accepted work, flushes touches, and is safe to call repeatedly.
  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closing = true;
    _touchTimer?.cancel();
    _touchTimer = null;
    return _closeFuture = _enqueue(() async {
      if (_initialized && _dirty) await _persistIndex();
    });
  }

  bool _expired(_DiskEntry entry) {
    final current = _now().millisecondsSinceEpoch;
    return entry.writtenAt > current ||
        current - entry.writtenAt >= maxAge.inMilliseconds;
  }

  void _scheduleTouch() {
    if (_closing || _touchTimer != null) return;
    _touchTimer = Timer(const Duration(milliseconds: 250), () {
      _touchTimer = null;
      unawaited(
        _enqueue(() async {
          if (_dirty) await _persistIndex();
        }).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    });
  }

  Future<void> _initialize() async {
    await _prepareRoot();
    final index = _file(_indexName);
    try {
      final type = await FileSystemEntity.type(index.path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        final limit = maxBytes < _maxIndexBytes ? maxBytes : _maxIndexBytes;
        final data = await _readBounded(index, limit);
        if (data != null) {
          final decoded = jsonDecode(utf8.decode(data));
          if (decoded is Map &&
              decoded['version'] == 1 &&
              decoded['entries'] is List) {
            for (final value in decoded['entries'] as List) {
              final entry = _parseEntry(value);
              if (entry == null || _entries.containsKey(entry.key)) continue;
              await _recoverBackup(entry);
              final file = _file(entry.key);
              if (await FileSystemEntity.type(file.path, followLinks: false) ==
                      FileSystemEntityType.file &&
                  await file.length() == entry.size) {
                _entries[entry.key] = entry;
              }
            }
          }
        }
      } else if (type == FileSystemEntityType.link) {
        await _deleteOwned(index);
      }
    } on FormatException {
      _entries.clear();
    } on FileSystemException {
      // Inaccessible/corrupt entries are disposable; actual cleanup failures
      // below still surface rather than silently violating the disk budget.
      _entries.clear();
    }
    await _sweep();
    _dirty = true;
    // Startup can lower the configured budget. Reclaim the old manifest first
    // if necessary; startup recovery itself is not a committed cache write.
    while (await _diskUsage() + _encodeIndex().length > maxBytes &&
        _entries.isNotEmpty) {
      await _discard(_entries.keys.first);
    }
    if (await _diskUsage() + _encodeIndex().length > maxBytes) {
      await _deleteOwned(index);
    }
    await _persistIndex();
    _initialized = true;
  }

  _DiskEntry? _parseEntry(Object? value) {
    if (value is! Map) return null;
    final key = value['key'];
    final size = value['size'];
    final writtenAt = value['writtenAt'];
    final checksum = value['checksum'];
    if (key is! String ||
        !_hashPattern.hasMatch(key) ||
        checksum is! String ||
        !_hashPattern.hasMatch(checksum) ||
        size is! int ||
        size <= 0 ||
        size > maxEntryBytes ||
        size > maxBytes ||
        writtenAt is! int ||
        writtenAt < 0) {
      return null;
    }
    final entry = _DiskEntry(
      key: key,
      size: size,
      writtenAt: writtenAt,
      checksum: checksum,
    );
    return _expired(entry) ? null : entry;
  }

  Future<void> _prepareRoot() async {
    if (_directory.parent.path == _directory.path) {
      throw FileSystemException(
        'Cache directory must not be a filesystem root',
        _directory.path,
      );
    }
    var ancestor = _directory;
    while (true) {
      final type = await FileSystemEntity.type(
        ancestor.path,
        followLinks: false,
      );
      // macOS exposes system temp paths through these OS-owned aliases.
      final systemAlias =
          Platform.isMacOS &&
          (ancestor.path == '/var' || ancestor.path == '/tmp');
      if (type == FileSystemEntityType.link && !systemAlias) {
        throw FileSystemException(
          'Cache directory must not traverse symbolic links',
          ancestor.path,
        );
      }
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory &&
          !(type == FileSystemEntityType.link && systemAlias)) {
        throw FileSystemException(
          'Cache ancestor is not a directory',
          ancestor.path,
        );
      }
      final parent = ancestor.parent;
      if (parent.path == ancestor.path) break;
      ancestor = parent;
    }
    await _directory.create(recursive: true);
    _directory = Directory(await _directory.resolveSymbolicLinks());
    await _checkRoot();
  }

  Future<void> _checkRoot() async {
    if (await FileSystemEntity.type(_directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await _directory.resolveSymbolicLinks() != _directory.path) {
      throw FileSystemException(
        'Cache directory changed or became a symbolic link',
        _directory.path,
      );
    }
  }

  Future<void> _discard(String key) async {
    _entries.remove(key);
    _dirty = true;
    await _deleteOwned(_file(key));
    await _deleteOwned(_file('$key.bak'));
    await _deleteOwned(_file('$key.part'));
  }

  Future<void> _recoverBackup(_DiskEntry entry) async {
    final backup = _file('${entry.key}.bak');
    final backupType = await FileSystemEntity.type(
      backup.path,
      followLinks: false,
    );
    if (backupType == FileSystemEntityType.notFound) return;
    final target = _file(entry.key);
    if (await _readEntry(target, entry) == null &&
        await _readEntry(backup, entry) != null) {
      await _prepareFresh(target);
      await backup.rename(target.path);
    } else {
      await _deleteOwned(backup);
    }
  }

  Future<Uint8List?> _readEntry(File file, _DiskEntry entry) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() != entry.size) {
        return null;
      }
      final bytes = await _readBounded(file, entry.size);
      if (bytes == null ||
          bytes.length != entry.size ||
          await _checksum(bytes) != entry.checksum) {
        return null;
      }
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  Future<Uint8List?> _readBounded(File file, int limit) async {
    if (await file.length() > limit) return null;
    final handle = await file.open();
    try {
      final builder = BytesBuilder(copy: false);
      while (builder.length <= limit) {
        final remaining = limit + 1 - builder.length;
        final chunk = await handle.read(remaining < 65536 ? remaining : 65536);
        if (chunk.isEmpty) return builder.takeBytes();
        builder.add(chunk);
      }
      return null;
    } finally {
      await handle.close();
    }
  }

  Future<void> _sweep() async {
    await for (final entity in _directory.list(followLinks: false)) {
      final name = entity.path.substring(_directory.path.length + 1);
      if (name == '$_indexName.part') {
        await _deleteOwned(_file(name));
      } else if (_ownedPattern.hasMatch(name)) {
        final hash = name.substring(0, 64);
        if (name.endsWith('.bak') && _entries.containsKey(hash)) {
          await _recoverBackup(_entries[hash]!);
        } else if (name.length != 64 || !_entries.containsKey(hash)) {
          await _deleteOwned(_file(name));
        }
      }
    }
  }

  Uint8List _encodeIndex([_DiskEntry? replacement]) {
    final entries = [
      for (final entry in _entries.values)
        if (entry.key != replacement?.key) entry.toJson(),
      if (replacement != null) replacement.toJson(),
    ];
    return Uint8List.fromList(
      utf8.encode(jsonEncode({'version': 1, 'entries': entries})),
    );
  }

  Future<bool> _makeRoom(_DiskEntry next) async {
    while (true) {
      final indexLength = _encodeIndex(next).length;
      if (indexLength <= _maxIndexBytes &&
          await _diskUsage() + next.size + indexLength <= maxBytes) {
        return true;
      }
      final victims = _entries.keys.where((key) => key != next.key);
      if (victims.isEmpty) {
        if (_dirty) await _persistIndex();
        return false;
      }
      await _discard(victims.first);
    }
  }

  // Stat actual files, including leftovers from failed cleanup, so a partial
  // write can never silently consume space outside the admission accounting.
  Future<int> _diskUsage() async {
    var bytes = 0;
    await for (final entity in _directory.list(followLinks: false)) {
      final name = entity.path.substring(_directory.path.length + 1);
      if ((name == _indexName ||
              name == '$_indexName.part' ||
              _ownedPattern.hasMatch(name)) &&
          await FileSystemEntity.type(entity.path, followLinks: false) ==
              FileSystemEntityType.file) {
        bytes += await File(entity.path).length();
      }
    }
    return bytes;
  }

  Future<void> _persistIndex() async {
    if (!_dirty) return;
    await _checkRoot();
    final part = _file('$_indexName.part');
    final index = _file(_indexName);
    await _prepareFresh(part);
    final type = await FileSystemEntity.type(index.path, followLinks: false);
    if (type == FileSystemEntityType.link) await _deleteOwned(index);
    if (type == FileSystemEntityType.directory) {
      throw FileSystemException('Cache index is a directory', index.path);
    }
    final encoded = _encodeIndex();
    // An empty cache needs no manifest. Extremely small budgets cannot reserve
    // two complete manifests for the next atomic replacement.
    if (_entries.isEmpty && encoded.length * 2 > maxBytes) {
      await _deleteOwned(index);
      _dirty = false;
      return;
    }
    if (encoded.length > _maxIndexBytes ||
        await _diskUsage() + encoded.length > maxBytes) {
      throw FileSystemException(
        'No room for an atomic cache index',
        index.path,
      );
    }
    try {
      await part.writeAsBytes(encoded, flush: true);
      await part.rename(index.path);
      _dirty = false;
    } catch (_) {
      await _bestEffortDelete(part);
      rethrow;
    }
  }

  Future<void> _prepareFresh(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file &&
        type != FileSystemEntityType.link) {
      throw FileSystemException('Cache path is not a regular file', file.path);
    }
    await _deleteOwned(file);
  }

  Future<void> _deleteOwned(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      await Link(file.path).delete();
    } else if (type == FileSystemEntityType.file) {
      await file.delete();
    }
  }

  Future<void> _bestEffortDelete(File file) async {
    try {
      await _deleteOwned(file);
    } on FileSystemException {
      // Recovered at the next sweep; _diskUsage keeps accounting for the file.
    }
  }
}

Future<String> _checksum(Uint8List bytes) =>
    Isolate.run(() => sha256.convert(bytes).toString());

Directory _normalizedDirectory(Directory directory) {
  var path = directory.absolute.uri.normalizePath().toFilePath();
  // Directory URIs append a slash. lstat("link/") follows the link on POSIX,
  // even when followLinks is false, so remove it before any security checks.
  while (path.endsWith(Platform.pathSeparator) &&
      Directory(path).parent.path != path) {
    path = path.substring(0, path.length - 1);
  }
  return Directory(path);
}

class _DiskEntry {
  const _DiskEntry({
    required this.key,
    required this.size,
    required this.writtenAt,
    required this.checksum,
  });

  final String key;
  final int size;
  final int writtenAt;
  final String checksum;

  Map<String, Object> toJson() => {
    'key': key,
    'size': size,
    'writtenAt': writtenAt,
    'checksum': checksum,
  };
}
