import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../domain/models/camera_file.dart';
import '../../domain/models/gallery_entry.dart' show isPhoto, photoIdentity;
import '../../domain/models/transfer_job.dart';
import '../../domain/models/transfer_progress.dart';
import '../../domain/ports/camera_adapter.dart';

/// A single-owner durable queue. Use one instance per dedicated state directory.
///
/// [add] and [retry] only save intent. [start]/[resume] run serially until idle.
/// Each attempt resolves an adapter anew; the resolver must validate the source
/// identity (including version/length/capture time) before returning it.
final class TransferQueue extends ChangeNotifier {
  TransferQueue({
    required this.directory,
    required this.resolveAdapter,
    this.onStart,
    this.onStop,
    this.onProgress,
  }) {
    ready = _load();
  }

  final Directory directory;
  final Future<CameraAdapter> Function(TransferJob) resolveAdapter;
  final Future<void> Function(int pending)? onStart;
  final Future<void> Function()? onStop;
  final Future<void> Function(TransferJob)? onProgress;
  late final Future<void> ready;
  final List<TransferJob> _jobs = [];
  Future<void> _writes = Future<void>.value();
  Future<void>? _runner;
  Future<void>? _closing;
  _Attempt? _active;
  bool _wanted = false;
  bool _closed = false;
  bool _running = false;
  String? _recoveryWarning;

  List<TransferJob> get jobs => List.unmodifiable(_jobs);
  bool get isRunning => _running;

  /// A backup was used; corrupt files are retained for diagnosis. If all copies
  /// are corrupt, [ready] throws instead of silently starting an empty queue.
  String? get recoveryWarning => _recoveryWarning;

  File get _state => File('${directory.path}/queue.json');
  File get _backup => File('${directory.path}/queue.json.bak');

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = _writes.then((_) => action());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _checkOpen() {
    if (_closed) throw StateError('TransferQueue is closed');
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  TransferJob _job(String id) => _jobs.firstWhere(
    (j) => j.id == id,
    orElse: () => throw ArgumentError.value(id, 'jobId', 'Unknown transfer'),
  );

  void _replace(TransferJob job) {
    _jobs[_jobs.indexWhere((j) => j.id == job.id)] = job;
  }

  Future<void> add({
    required String cameraId,
    required List<CameraFile> files,
    required Directory destination,
  }) async {
    _checkOpen();
    await ready;
    await _exclusive(() async {
      _checkOpen();
      if (cameraId.isEmpty) throw ArgumentError('cameraId is empty');
      if (files.any((f) => f.byteLength < 0)) {
        throw ArgumentError('Original file length must be nonnegative');
      }
      // The queue must never save a job that it would reject on restart.
      if (files.any(
        (f) =>
            f.name.isEmpty ||
            f.name.length > 1024 ||
            f.name.contains(RegExp(r'[/\\\x00]')) ||
            (f.directory?.length ?? 0) > 2048,
      )) {
        throw ArgumentError('Invalid camera source name or directory');
      }
      final additions = <TransferJob>[];
      final occupied = _jobs
          .map((j) => j.destinationPath.toLowerCase())
          .toSet();
      for (final file in files) {
        // Avoid duplicate pending work when the same source is selected twice.
        // A camera handle and metadata do not prove equal original bytes.
        if (file.thumbnailKey != null &&
            (await _alreadyImported(
              cameraId: cameraId,
              file: file,
              destination: destination,
              additions: additions,
            ))) {
          continue;
        }
        final id = _newId();
        final path = await _available(
          destination.absolute.path,
          _safeName(file.name),
          occupied,
        );
        occupied.add(path.toLowerCase());
        additions.add(
          TransferJob(
            id: id,
            cameraFileId: file.id,
            cameraId: cameraId,
            fileName: _basename(path),
            sourceVersion: file.thumbnailKey,
            sourceCapturedAt: file.capturedAt,
            sourceName: file.name,
            sourceDirectory: file.directory,
            photoIdentity: isPhoto(file)
                ? photoIdentity(file, cameraId: cameraId)
                : null,
            destinationPath: path,
            temporaryPath: '${destination.absolute.path}/.camera-$id.part',
            state: TransferState.queued,
            bytesTransferred: 0,
            totalBytes: file.byteLength,
            attemptCount: 0,
          ),
        );
        // Apply the same schema rules used on restart before publishing state.
        TransferJob.fromJson(additions.last.toJson());
      }
      if (additions.isEmpty) return;
      // Publish the new jobs only after durable save succeeds.
      await _save([..._jobs, ...additions]);
      _jobs.addAll(additions);
      _notify();
    });
  }

  Future<bool> _alreadyImported({
    required String cameraId,
    required CameraFile file,
    required Directory destination,
    required List<TransferJob> additions,
  }) async {
    for (final job in [..._jobs, ...additions]) {
      if (job.cameraId != cameraId ||
          job.cameraFileId != file.id ||
          job.sourceVersion != file.thumbnailKey ||
          (job.sourceName != null && job.sourceName != file.name) ||
          (job.sourceName != null && job.sourceDirectory != file.directory) ||
          job.sourceCapturedAt != file.capturedAt ||
          job.totalBytes != file.byteLength ||
          File(job.destinationPath).parent.absolute.path !=
              destination.absolute.path) {
        continue;
      }
      if (job.state == TransferState.queued ||
          job.state == TransferState.connecting ||
          job.state == TransferState.copying ||
          job.state == TransferState.interrupted) {
        return true;
      }
      // A completed file's local hash only verifies local bytes. Camera
      // metadata may stay the same after a source rewrite, so a repeat import
      // gets a distinct path until the camera supplies a source checksum.
    }
    return false;
  }

  Future<void> start() {
    _checkOpen();
    if (_runner != null) return _runner!;
    _wanted = true;
    final future = _run();
    _runner = future;
    return future;
  }

  Future<void> resume() => start();

  Future<void> pause() async {
    if (_closed) return;
    _wanted = false;
    _active?.abort();
    await _runner;
    await ready;
    await _writes;
  }

  Future<void> retry(String jobId) async {
    _checkOpen();
    await ready;
    await _exclusive(() async {
      final job = _job(jobId);
      if (job.state == TransferState.completed || _active?.id == jobId) return;
      final next = job.copyWith(state: TransferState.queued, clearError: true);
      await _save(_with(next));
      _replace(next);
      _notify();
    });
  }

  Future<void> cancel(String jobId) async {
    _checkOpen();
    await ready;
    final active = _active;
    if (active?.id == jobId) {
      active!.cancelled = true;
      active.abort();
      await active.finished.future;
    }
    await _exclusive(() async {
      final job = _job(jobId);
      if (job.state == TransferState.completed ||
          job.state == TransferState.cancelled) {
        return;
      }
      final next = job.copyWith(
        state: TransferState.cancelled,
        lastError: 'User cancelled; partial retained for retry',
      );
      await _save(_with(next));
      _replace(next);
      _notify();
    });
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _wanted = false;
    _active?.abort();
    try {
      await _runner;
      // Initialization failure is already reported by ready. Closing a broken
      // store must still release the notifier without rewriting that store.
      try {
        await ready;
      } catch (_) {
        /* Keep corrupt state untouched. */
      }
      await _writes;
    } finally {
      super.dispose();
    }
  }

  List<TransferJob> _with(TransferJob job) => [
    for (final old in _jobs)
      if (old.id == job.id) job else old,
  ];

  Future<void> _run() async {
    var hooksStarted = false;
    final tried = <String>{};
    try {
      await ready;
      if (!_wanted) return;
      final pending = _jobs.where(_eligible).length;
      if (pending == 0) return;
      _running = true;
      _notify();
      hooksStarted = true;
      await onStart?.call(pending);
      while (_wanted) {
        final candidates = _jobs.where(
          (j) => _eligible(j) && !tried.contains(j.id),
        );
        if (candidates.isEmpty) break;
        final id = candidates.first.id;
        tried.add(id);
        // At most three attempts per explicit start, never an infinite retry loop.
        for (var attempt = 0; attempt < 3 && _wanted; attempt++) {
          final transient = await _transfer(id);
          if (!transient) break;
          if (attempt < 2 && _wanted) {
            // Bounded backoff; pause/cancel do not wait for this timer.
            final signal = _Attempt(id);
            _active = signal;
            try {
              await signal.wait(
                Future<void>.delayed(
                  Duration(milliseconds: 100 * (attempt + 1)),
                ),
              );
            } on _Aborted {
              break;
            } finally {
              if (identical(_active, signal)) _active = null;
              signal.finished.complete();
            }
            if (_job(id).state == TransferState.cancelled) break;
          }
        }
      }
    } finally {
      try {
        if (hooksStarted) await onStop?.call();
      } finally {
        _running = false;
        _wanted = false;
        _runner = null;
        _notify();
      }
    }
  }

  bool _eligible(TransferJob job) =>
      job.state == TransferState.queued ||
      job.state == TransferState.interrupted;

  Future<bool> _transfer(String id) async {
    final active = _Attempt(id);
    _active = active;
    try {
      await _exclusive(() async {
        active.check();
        var job = await _reconcile(_job(id));
        if (job.state == TransferState.completed) {
          await _save(_with(job));
          _replace(job);
          return;
        }
        if (job.lastError?.startsWith('Partial length') ?? false) {
          throw const _ValidationError(
            'Partial length exceeds expected original length; preserve and inspect the partial',
          );
        }
        job = job.copyWith(
          state: TransferState.connecting,
          attemptCount: job.attemptCount + 1,
          clearError: true,
        );
        await _save(_with(job));
        _replace(job);
        _notify();
      });
      if (_job(id).state == TransferState.completed) return false;
      active.check();
      var job = _job(id);
      // Source identity is validated by the parent's resolver on EVERY attempt.
      final adapter = await active.wait(resolveAdapter(job));
      active.check();
      final partial = File(job.temporaryPath!);
      await partial.parent.create(recursive: true);
      active.check();
      final type = await FileSystemEntity.type(
        partial.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw const _ValidationError('Unsafe partial path');
      }
      await _exclusive(() async {
        active.check();
        job = _job(id).copyWith(state: TransferState.copying);
        await _save(_with(job));
        _replace(job);
        _notify();
      });
      active.check();
      if (await _partialLength(job) < job.totalBytes) {
        await _consume(adapter, job, active);
      } else if (!await partial.exists() && job.totalBytes == 0) {
        await partial.create(exclusive: true);
      }
      active.check();
      if (!await partial.exists() || await partial.length() != job.totalBytes) {
        throw const _ValidationError(
          'Original length mismatch; incomplete partial retained',
        );
      }
      final handle = await partial.open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
      active.check();
      final checksum = await active.wait(_hash(partial, active: active));
      active.check();
      if (job.commitPending &&
          job.checksum != null &&
          checksum != job.checksum) {
        throw const _ValidationError(
          'Partial checksum mismatch; file retained without committing',
        );
      }
      await _exclusive(() async {
        active.check();
        var next = _job(id).copyWith(
          checksum: checksum,
          commitPending: true,
          bytesTransferred: job.totalBytes,
        );
        while (true) {
          // Persist the exact destination and hash before the rename. A crash
          // after rename is reconciled only with the matching length AND hash.
          final occupied = _jobs
              .where((j) => j.id != id)
              .map((j) => j.destinationPath.toLowerCase())
              .toSet();
          final path = await _available(
            File(next.destinationPath).parent.path,
            next.fileName,
            occupied,
          );
          next = next.copyWith(
            destinationPath: path,
            fileName: _basename(path),
          );
          await _save(_with(next));
          _replace(next);
          active.check();
          if (!_commitReserved(partial, next)) continue;
          active.committed = true;
          next = next.copyWith(
            state: TransferState.completed,
            commitPending: false,
            clearError: true,
          );
          await _save(_with(next));
          _replace(next);
          _notify();
          break;
        }
      });
      await onProgress?.call(_job(id));
      return false;
    } catch (error) {
      await active.cancelSubscription();
      final cleanupError = active.cleanupError;
      if (cleanupError != null) _wanted = false;
      // Once renamed, never pretend cancellation or a callback failure undid it.
      if (active.committed) {
        final job = await _reconcile(_job(id));
        await _exclusive(() async {
          await _save(_with(job));
          _replace(job);
          _notify();
        });
        return false;
      }
      final aborted = error is _Aborted;
      final transient = cleanupError == null && !aborted && _isTransient(error);
      await _exclusive(() async {
        final job = _job(id);
        final count = await _partialLength(job);
        final next = job.copyWith(
          state: active.cancelled
              ? TransferState.cancelled
              : cleanupError != null
              ? TransferState.failed
              : aborted || transient
              ? TransferState.interrupted
              : TransferState.failed,
          bytesTransferred: count,
          lastError: cleanupError != null
              ? 'Download cancellation failed; batch stopped; partial retained: $cleanupError'
              : active.cancelled
              ? 'User cancelled; partial retained for retry'
              : aborted
              ? 'Paused; partial retained for resume'
              : _describe(error),
        );
        await _save(_with(next));
        _replace(next);
        _notify();
      });
      return transient;
    } finally {
      try {
        await active.cancelSubscription();
      } finally {
        if (identical(_active, active)) _active = null;
        active.finished.complete();
      }
    }
  }

  Future<void> _consume(
    CameraAdapter adapter,
    TransferJob job,
    _Attempt active,
  ) async {
    final done = Completer<void>();
    var updates = Future<void>.value();
    void fail(Object error, StackTrace stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    }

    active.subscription = adapter
        .downloadOriginal(job.cameraFileId, job.temporaryPath!)
        .listen(
          (progress) {
            active.subscription?.pause();
            updates = updates.then((_) async {
              active.check();
              await _exclusive(() async {
                active.check();
                final bytes = await _partialLength(job);
                active.check();
                final next = _job(job.id).copyWith(bytesTransferred: bytes);
                await _save(_with(next));
                if (!active.aborted) {
                  _replace(next);
                  _notify();
                }
              });
              active.check();
              await onProgress?.call(_job(job.id));
            });
            // Observe errors immediately; don't allow queued progress failures to
            // escape or mutate a subsequent attempt.
            updates = updates
                .catchError((Object error, StackTrace stack) {
                  fail(error, stack);
                })
                .whenComplete(() {
                  if (!active.aborted) active.subscription?.resume();
                });
          },
          onError: fail,
          onDone: () async {
            await updates;
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: false,
        );
    try {
      await active.wait(done.future);
      await updates;
    } finally {
      await active.cancelSubscription();
      await updates;
      if (active.cleanupError != null) {
        throw _ValidationError(
          'Download cancellation failed: ${active.cleanupError}',
        );
      }
    }
  }

  Future<int> _partialLength(TransferJob job) async {
    if (job.temporaryPath == null) return 0;
    final type = await FileSystemEntity.type(
      job.temporaryPath!,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return 0;
    if (type != FileSystemEntityType.file) {
      throw const _ValidationError('Unsafe partial path');
    }
    return File(job.temporaryPath!).length();
  }

  Future<TransferJob> _reconcile(TransferJob job) async {
    if (job.state == TransferState.completed) {
      final destination = File(job.destinationPath);
      // A completed queue record is not evidence that the published file still
      // exists or contains the bytes verified when it was imported.
      try {
        if (job.checksum != null &&
            await FileSystemEntity.type(destination.path, followLinks: false) ==
                FileSystemEntityType.file &&
            await destination.length() == job.totalBytes &&
            await _hash(destination) == job.checksum) {
          return job;
        }
      } on FileSystemException {
        // A removed volume or revoked permission affects this entry, not the
        // entire queue. Keep the original path and let the user retry.
      }
      return job.copyWith(
        state: TransferState.failed,
        lastError: '已导入文件缺失、不可读取或内容已变化；原目标保留，请检查后重新导入',
      );
    }
    final partialLength = await _partialLength(job);
    final partialExists =
        job.temporaryPath != null && await File(job.temporaryPath!).exists();
    if (job.commitPending && job.checksum != null && partialExists) {
      // Crash after exclusive reservation but before rename. Never remove an
      // arbitrary same-name file, including a zero-byte file of unknown origin.
      _releaseReservation(job);
    }
    if (job.commitPending && job.checksum != null && !partialExists) {
      final file = File(job.destinationPath);
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.file &&
          await file.length() == job.totalBytes &&
          await _hash(file) == job.checksum) {
        return job.copyWith(
          state: TransferState.completed,
          bytesTransferred: job.totalBytes,
          commitPending: false,
          clearError: true,
        );
      }
      return job.copyWith(
        state: TransferState.failed,
        lastError: 'Committed file length/checksum mismatch; original destination preserved',
      );
    }
    return job.copyWith(
      bytesTransferred: partialLength,
      state: partialLength > job.totalBytes
          ? TransferState.failed
          : job.state == TransferState.copying ||
                job.state == TransferState.connecting
          ? TransferState.interrupted
          : job.state,
      lastError: partialLength > job.totalBytes
          ? 'Partial length exceeds expected original length; preserved without appending'
          : null,
    );
  }

  Future<void> _load() async {
    await directory.create(recursive: true);
    List<TransferJob>? loaded;
    var hadState = false;
    for (final candidate in [_state, _backup, File('${_state.path}.tmp')]) {
      if (!await candidate.exists()) continue;
      hadState = true;
      try {
        final decoded =
            jsonDecode(await candidate.readAsString()) as Map<String, dynamic>;
        if (decoded['version'] != 1 || decoded['jobs'] is! List) {
          throw const FormatException('Unsupported queue state');
        }
        final jobs = (decoded['jobs'] as List)
            .map((e) => TransferJob.fromJson(e as Map<String, dynamic>))
            .toList();
        for (final job in jobs) {
          _validateStoredPaths(job);
        }
        if (jobs.map((j) => j.id).toSet().length != jobs.length) {
          throw const FormatException('Duplicate transfer ids');
        }
        loaded = jobs;
        if (candidate.path != _state.path) {
          _recoveryWarning =
              'Queue state damaged or missing; recovered ${jobs.length} jobs from ${_basename(candidate.path)}';
          if (await _state.exists()) {
            await _state.copy('${_state.path}.corrupt-${_newId()}');
          }
        }
        break;
      } on FileSystemException {
        rethrow; // Permission/I/O errors must not be treated as an empty queue.
      } catch (_) {
        // Try the intact backup; never drop malformed individual rows silently.
      }
    }
    if (loaded == null && hadState) {
      throw const FormatException(
        'Queue state and backup are corrupt; files preserved',
      );
    }
    if (loaded == null) return;
    final recovered = <TransferJob>[];
    for (var job in loaded) {
      if (job.temporaryPath == null) {
        job = job.copyWith(
          temporaryPath:
              '${File(job.destinationPath).parent.path}/.camera-${_newId()}.part',
        );
      }
      if (job.fileName.isEmpty) {
        job = job.copyWith(fileName: _safeName(_basename(job.destinationPath)));
      }
      recovered.add(await _reconcile(job));
    }
    await _save(recovered);
    _jobs.addAll(recovered);
    _notify();
  }

  Future<void> _save(List<TransferJob> jobs) async {
    final data = jsonEncode({
      'version': 1,
      'jobs': jobs.map((j) => j.toJson()).toList(),
    });
    final temp = File('${_state.path}.tmp');
    await temp.writeAsString(data, flush: true);
    await temp.rename(_state.path);
    // The backup is the same committed snapshot, not an intentionally stale
    // preceding generation that would silently lose the newest additions.
    final backupTemp = File('${_backup.path}.tmp');
    await backupTemp.writeAsString(data, flush: true);
    await backupTemp.rename(_backup.path);
  }

  static Future<String> _hash(File file, {_Attempt? active}) async =>
      (await sha256
              .bind(
                file.openRead().map((bytes) {
                  active?.check();
                  return bytes;
                }),
              )
              .first)
          .toString();

  static String _reservation(TransferJob job) =>
      'sony-camera-reservation-v1\n${job.id}\n${job.checksum}\n';

  static void _validateStoredPaths(TransferJob job) {
    final destination = File(job.destinationPath);
    final name = job.fileName.isEmpty
        ? _basename(job.destinationPath)
        : job.fileName;
    if (!destination.isAbsolute ||
        name != _safeName(name) ||
        _basename(job.destinationPath) != name ||
        (job.commitPending && job.checksum == null)) {
      throw const FormatException(
        'Unsafe transfer destination or commit intent',
      );
    }
    final partial = job.temporaryPath;
    if (partial != null &&
        (!File(partial).isAbsolute ||
            File(partial).parent.path != destination.parent.path ||
            _basename(partial) != _safeName(_basename(partial)) ||
            !partial.endsWith('.part') ||
            partial == destination.path)) {
      throw const FormatException('Unsafe transfer partial path');
    }
  }

  static void _releaseReservation(TransferJob job) {
    final file = File(job.destinationPath);
    final marker = utf8.encode(_reservation(job));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
            FileSystemEntityType.file &&
        file.lengthSync() == marker.length &&
        listEquals(file.readAsBytesSync(), marker)) {
      file.deleteSync();
    }
  }

  static bool _commitReserved(File partial, TransferJob job) {
    final destination = File(job.destinationPath);
    try {
      // Unlike rename, exclusive create never overwrites an existing file, even
      // if another importer creates it after the preceding collision scan.
      destination.createSync(exclusive: true);
    } on FileSystemException {
      if (FileSystemEntity.typeSync(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return false;
      }
      rethrow;
    }
    try {
      // A brief, identifiable reservation is the only final-path content before
      // atomic publication of the original. A crash before this marker is
      // written may leave an empty file; preserve it rather than guess ownership.
      destination.writeAsStringSync(_reservation(job), flush: true);
      partial.renameSync(destination.path);
      return true;
    } catch (_) {
      _releaseReservation(job);
      rethrow;
    }
  }

  static bool _isTransient(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is HttpException;

  static String _describe(Object error) {
    if (error is FileSystemException &&
        (error.osError?.errorCode == 28 ||
            error.osError?.errorCode == 112 ||
            error.toString().toLowerCase().contains('space'))) {
      return 'Insufficient storage; partial retained for retry: $error';
    }
    return error.toString();
  }

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${List.generate(4, (_) => Random.secure().nextInt(1 << 32).toRadixString(16)).join()}';
  static String _basename(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  static String _safeName(String name) {
    var value = _basename(name)
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (value.isEmpty || value == '.' || value == '..') value = 'original';
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(value)) {
      value = '_$value';
    }
    // Bound UTF-8 bytes conservatively for common filesystems, preserving suffix.
    if (utf8.encode(value).length > 180) {
      final dot = value.lastIndexOf('.');
      final suffix = dot > 0 && value.length - dot < 20
          ? value.substring(dot)
          : '';
      var stem = '';
      for (final rune in value.runes) {
        final next = stem + String.fromCharCode(rune);
        if (utf8.encode(next + suffix).length > 180) break;
        stem = next;
      }
      value = stem + suffix;
    }
    return value;
  }

  static Future<String> _available(
    String directory,
    String name,
    Set<String> occupied,
  ) async {
    name = _safeName(name);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    // Case-fold even on case-sensitive hosts for portable queue destinations.
    final existing = <String>{};
    if (await Directory(directory).exists()) {
      await for (final entry in Directory(directory).list(followLinks: false)) {
        existing.add(_basename(entry.path).toLowerCase());
      }
    }
    for (var suffix = 0; ; suffix++) {
      final candidateName = suffix == 0 ? name : '$stem ($suffix)$extension';
      final path = '$directory/$candidateName';
      if (!occupied.contains(path.toLowerCase()) &&
          !existing.contains(candidateName.toLowerCase()) &&
          await FileSystemEntity.type(path, followLinks: false) ==
              FileSystemEntityType.notFound) {
        return path;
      }
    }
  }
}

final class _Attempt {
  _Attempt(this.id);
  final String id;
  final Completer<void> _abort = Completer<void>();
  final Completer<void> finished = Completer<void>();
  StreamSubscription<TransferProgress>? subscription;
  Future<void>? _cancelling;
  bool cancelled = false;
  bool committed = false;
  Object? cleanupError;
  bool get aborted => _abort.isCompleted;
  void check() {
    if (aborted) throw const _Aborted();
  }

  void abort() {
    if (!aborted) _abort.complete();
  }

  Future<T> wait<T>(Future<T> future) => Future.any([
    future,
    _abort.future.then<T>((_) => throw const _Aborted()),
  ]);
  Future<void> cancelSubscription() => _cancelling ??= _cancelSubscription();
  Future<void> _cancelSubscription() async {
    try {
      await subscription?.cancel();
    } catch (error) {
      // Report cleanup failure durably, but never strand finished/cancel callers.
      cleanupError = error;
    }
  }
}

final class _Aborted implements Exception {
  const _Aborted();
}

final class _ValidationError implements Exception {
  const _ValidationError(this.message);
  final String message;
  @override
  String toString() => message;
}
