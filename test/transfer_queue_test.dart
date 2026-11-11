import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camport/domain/models/camera_file.dart';
import 'package:camport/domain/models/transfer_job.dart';
import 'package:camport/domain/models/transfer_progress.dart';
import 'package:camport/domain/ports/camera_adapter.dart';
import 'package:camport/features/import_queue/transfer_queue.dart';

CameraFile source({String id = 'one', String name = 'DSC.ARW', int size = 6}) =>
    CameraFile(
      id: id,
      name: name,
      extension: 'ARW',
      format: CameraFileFormat.raw,
      byteLength: size,
      thumbnailKey: 'version:$id',
      capturedAt: DateTime.utc(2026, 11, 10),
    );

/// Writes real bytes in controlled chunks, resuming from the file's length.
class ControlledAdapter implements CameraAdapter {
  final List<int> bytes = [0, 1, 2, 3, 254, 255];
  final List<int> offsets = [];
  int calls = 0;
  int cancellations = 0;
  bool finish = true;
  Object? failure;
  Object? cancellationFailure;
  int? limit;
  int chunkSize = 2;
  Future<void> Function(String)? beforeWrite;
  final List<StreamController<TransferProgress>> streams = [];

  @override
  Stream<TransferProgress> downloadOriginal(String fileId, String path) {
    calls++;
    late StreamController<TransferProgress> controller;
    var cancelled = false;
    controller = StreamController<TransferProgress>(
      onListen: () async {
        await beforeWrite?.call(path);
        if (cancelled) return;
        final file = File(path);
        final offset = await file.exists() ? await file.length() : 0;
        offsets.add(offset);
        if (failure != null) {
          controller.addError(failure!);
          await controller.close();
          return;
        }
        final end = limit ?? bytes.length;
        for (var cursor = offset; cursor < end;) {
          if (cancelled) return;
          final next = (cursor + chunkSize).clamp(0, end);
          await file.writeAsBytes(
            bytes.sublist(cursor, next),
            mode: FileMode.append,
            flush: true,
          );
          if (cancelled) return;
          cursor = next;
          controller.add(
            TransferProgress(
              bytesTransferred: cursor,
              totalBytes: bytes.length,
            ),
          );
        }
        if (finish) await controller.close();
      },
      onCancel: () async {
        cancelled = true;
        cancellations++;
        if (cancellationFailure != null) throw cancellationFailure!;
      },
    );
    streams.add(controller);
    return controller.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 1000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Condition did not become true');
}

void main() {
  late Directory root;
  late Directory state;
  late Directory destination;
  late ControlledAdapter adapter;
  final opened = <TransferQueue>[];

  TransferQueue queue({
    Future<void> Function(int)? onStart,
    Future<void> Function()? onStop,
    Future<void> Function(TransferJob)? onProgress,
  }) {
    final result = TransferQueue(
      directory: state,
      resolveAdapter: (job) async => adapter,
      onStart: onStart,
      onStop: onStop,
      onProgress: onProgress,
    );
    opened.add(result);
    return result;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('transfer-queue-');
    state = Directory('${root.path}/state');
    destination = Directory('${root.path}/originals');
    adapter = ControlledAdapter();
  });
  tearDown(() async {
    for (final q in opened.reversed) {
      await q.close();
    }
    opened.clear();
    await root.delete(recursive: true);
  });

  test(
    'add is durable without downloading; one batch is serial and hashed',
    () async {
      var starts = 0;
      var stops = 0;
      final q = queue(
        onStart: (pending) async {
          starts++;
          expect(pending, 2);
        },
        onStop: () async {
          stops++;
        },
      );
      await q.add(
        cameraId: 'camera',
        files: [
          source(),
          source(id: 'two'),
        ],
        destination: destination,
      );
      expect(adapter.calls, 0);
      adapter.beforeWrite = (path) async {
        final json = jsonDecode(
          await File('${state.path}/queue.json').readAsString(),
        ) as Map;
        expect(
          (json['jobs'] as List).where((j) => j['state'] == 'copying'),
          hasLength(1),
        );
        expect(path, endsWith('.part'));
      };
      final run = q.start();
      await Future.wait([run, q.start()]);
      expect(starts, 1);
      expect(stops, 1);
      expect(q.isRunning, false);
      for (final job in q.jobs) {
        expect(job.state, TransferState.completed);
        expect(job.checksum, sha256.convert(adapter.bytes).toString());
        expect(await File(job.destinationPath).readAsBytes(), adapter.bytes);
        expect(job.cameraId, 'camera');
        expect(job.sourceVersion, 'version:${job.cameraFileId}');
        expect(job.sourceCapturedAt, DateTime.utc(2026, 11, 10));
      }
      expect(q.jobs.map((j) => j.destinationPath).toSet(), hasLength(2));
      await q.close();
      final reopened = queue();
      await reopened.ready;
      expect(
        reopened.jobs.every((j) => j.state == TransferState.completed),
        true,
      );
    },
  );

  test('pause cancels a never-ending stream; restart resumes actual partial length', () async {
    adapter.finish = false;
    adapter.limit = 3;
    var stops = 0;
    final q = queue(
      onStop: () async {
        stops++;
      },
    );
    await q.add(
      cameraId: 'camera',
      files: [source()],
      destination: destination,
    );
    final run = q.start();
    await until(() => q.jobs.single.bytesTransferred == 3);
    await q.pause();
    await run;
    expect(stops, 1);
    expect(adapter.cancellations, 1);
    expect(q.jobs.single.state, TransferState.interrupted);
    await q.close();
    // The persisted progress is deliberately stale: actual file length wins.
    await File(q.jobs.single.temporaryPath!)
        .writeAsBytes([3], mode: FileMode.append);
    adapter = ControlledAdapter();
    final reopened = queue();
    await reopened.ready;
    expect(reopened.jobs.single.bytesTransferred, 4);
    await reopened.resume();
    expect(adapter.offsets, [4]);
    expect(reopened.jobs.single.state, TransferState.completed);
  });

  test('cancel aborts await and stale events cannot complete; explicit retry works', () async {
    adapter.finish = false;
    adapter.limit = 2;
    final q = queue();
    await q.add(
      cameraId: 'camera',
      files: [source()],
      destination: destination,
    );
    final run = q.start();
    await until(() => q.jobs.single.bytesTransferred == 2);
    await q.cancel(q.jobs.single.id);
    await run;
    expect(q.jobs.single.state, TransferState.cancelled);
    expect(adapter.cancellations, 1);
    adapter.streams.single.add(const TransferProgress(bytesTransferred: 6));
    await Future<void>.delayed(Duration.zero);
    expect(q.jobs.single.state, TransferState.cancelled);
    adapter = ControlledAdapter();
    await q.retry(q.jobs.single.id);
    await q.start();
    expect(adapter.offsets, [2]);
    expect(q.jobs.single.state, TransferState.completed);
  });

  test(
    'safe basenames and collisions preserve all preexisting bytes',
    () async {
      await destination.create();
      final existing = File('${destination.path}/DSC.ARW');
      await existing.writeAsString('keep me');
      final q = queue();
      await q.add(
        cameraId: 'camera',
        files: [
          source(),
          source(id: 'escape', name: 'CON:<>.ARW'),
          source(id: 'reserved', name: 'AUX.ARW'),
          source(id: 'illegal', name: 'name:with?illegal*.ARW'),
        ],
        destination: destination,
      );
      await q.start();
      expect(await existing.readAsString(), 'keep me');
      for (final job in q.jobs) {
        expect(File(job.destinationPath).parent.path, destination.path);
        expect(job.fileName, isNot(matches(r'[<>:"/\\|?*]')));
        expect(job.fileName.toUpperCase(), isNot('CON.ARW'));
        expect(await File(job.destinationPath).readAsBytes(), adapter.bytes);
      }
    },
  );

  test('short stream and oversized partial never become completed', () async {
    adapter.limit = 3;
    final q = queue();
    await q.add(
      cameraId: 'camera',
      files: [source()],
      destination: destination,
    );
    await q.start();
    expect(q.jobs.single.state, TransferState.failed);
    expect(q.jobs.single.lastError, contains('length'));
    expect(await File(q.jobs.single.destinationPath).exists(), false);
    await File(q.jobs.single.temporaryPath!).writeAsBytes(List.filled(7, 0));
    final calls = adapter.calls;
    await q.retry(q.jobs.single.id);
    await q.start();
    expect(q.jobs.single.state, TransferState.failed);
    expect(adapter.calls, calls);
    expect(await File(q.jobs.single.temporaryPath!).length(), 7);
  });

  test(
    'transient failures are bounded; storage full fails without retrying',
    () async {
      adapter.failure = const SocketException('offline');
      var stops = 0;
      final q = queue(
        onStop: () async {
          stops++;
        },
      );
      await q.add(
        cameraId: 'camera',
        files: [source()],
        destination: destination,
      );
      await q.start();
      expect(adapter.calls, 3);
      expect(q.jobs.single.state, TransferState.interrupted);
      expect(stops, 1);
      adapter.failure = const FileSystemException(
        'No space left on device',
        '',
        OSError('full', 28),
      );
      await q.retry(q.jobs.single.id);
      await q.start();
      expect(adapter.calls, 4);
      expect(q.jobs.single.state, TransferState.failed);
      expect(q.jobs.single.lastError, contains('storage'));
    },
  );

  test(
    'corrupt primary reports backup recovery; both corrupt do not erase queue',
    () async {
      final q = queue();
      await q.add(
        cameraId: 'camera',
        files: [source()],
        destination: destination,
      );
      await q.close();
      await File('${state.path}/queue.json').writeAsString('{broken');
      final recovered = queue();
      await recovered.ready;
      expect(recovered.jobs, hasLength(1));
      expect(recovered.recoveryWarning, isNotNull);
      await recovered.close();
      await File('${state.path}/queue.json').writeAsString('{broken');
      await File('${state.path}/queue.json.bak').writeAsString('{broken');
      final broken = queue();
      await expectLater(broken.ready, throwsFormatException);
      expect(await File('${state.path}/queue.json').readAsString(), '{broken');
    },
  );

  test(
    'reopen restores interrupted and completes a persisted rename intent',
    () async {
      final q = queue();
      await q.add(
        cameraId: 'camera',
        files: [source()],
        destination: destination,
      );
      await q.start();
      await q.close();
      final file = File('${state.path}/queue.json');
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final job = (json['jobs'] as List).single as Map<String, dynamic>;
      job['state'] = 'copying'; // Crash after rename, before completed state.
      job['commitPending'] = true;
      await file.writeAsString(jsonEncode(json));
      final reopened = queue();
      await reopened.ready;
      expect(reopened.jobs.single.state, TransferState.completed);
      expect(adapter.calls, 1);
    },
  );

  test('rename intent never trusts a different local checksum', () async {
    final q = queue();
    await q.add(
      cameraId: 'camera',
      files: [source()],
      destination: destination,
    );
    await q.start();
    await q.close();
    await File(q.jobs.single.destinationPath).writeAsBytes([9, 9, 9, 9, 9, 9]);
    final file = File('${state.path}/queue.json');
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final job = (json['jobs'] as List).single as Map<String, dynamic>;
    job['state'] = 'copying';
    job['commitPending'] = true;
    await file.writeAsString(jsonEncode(json));
    final reopened = queue();
    await reopened.ready;
    expect(reopened.jobs.single.state, TransferState.failed);
    expect(reopened.jobs.single.lastError, contains('checksum'));
  });

  test(
    'cancel while resolving releases batch and late resolution is inert',
    () async {
      final resolver = Completer<CameraAdapter>();
      var resolutions = 0;
      var stops = 0;
      final q = TransferQueue(
        directory: state,
        resolveAdapter: (job) {
          resolutions++;
          return resolver.future;
        },
        onStop: () async {
          stops++;
        },
      );
      opened.add(q);
      await q.add(
        cameraId: 'camera',
        files: [source()],
        destination: destination,
      );
      final run = q.start();
      await until(() => resolutions == 1);
      await q.cancel(q.jobs.single.id);
      await run;
      resolver.complete(adapter);
      await Future<void>.delayed(Duration.zero);
      expect(adapter.calls, 0);
      expect(stops, 1);
      expect(q.jobs.single.state, TransferState.cancelled);
    },
  );

  test(
    'failed persistence publishes no job and starts no destination IO',
    () async {
      final q = queue();
      await q.ready;
      await Directory('${state.path}/queue.json.tmp').create();
      await expectLater(
        q.add(cameraId: 'camera', files: [source()], destination: destination),
        throwsA(isA<FileSystemException>()),
      );
      expect(q.jobs, isEmpty);
      expect(await destination.exists(), false);
      await q.start();
      expect(adapter.calls, 0);
    },
  );

  test(
    'reopen copying corrects stale byte count and does not start automatically',
    () async {
      final q = queue();
      await q.add(
        cameraId: 'camera',
        files: [source()],
        destination: destination,
      );
      await q.close();
      final partial = File(q.jobs.single.temporaryPath!);
      await partial.parent.create(recursive: true);
      await partial.writeAsBytes([0, 1]);
      final file = File('${state.path}/queue.json');
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final job = (json['jobs'] as List).single as Map<String, dynamic>;
      job['state'] = 'copying';
      job['bytesTransferred'] = 5;
      await file.writeAsString(jsonEncode(json));
      final reopened = queue();
      await reopened.ready;
      expect(reopened.jobs.single.state, TransferState.interrupted);
      expect(reopened.jobs.single.bytesTransferred, 2);
      expect(adapter.calls, 0);
      await reopened.start();
      expect(adapter.offsets, [2]);
    },
  );

  test('a destination appearing during download is preserved', () async {
    final q = queue();
    await q.add(
      cameraId: 'camera',
      files: [source()],
      destination: destination,
    );
    final originalPath = q.jobs.single.destinationPath;
    adapter.beforeWrite = (path) async {
      await File(originalPath).writeAsString('concurrent file');
    };
    await q.start();
    expect(q.jobs.single.state, TransferState.completed);
    expect(q.jobs.single.destinationPath, isNot(originalPath));
    expect(await File(originalPath).readAsString(), 'concurrent file');
  });

  test(
    'background start failure always stops and keeps durable queued jobs',
    () async {
      var stops = 0;
      final q = queue(
        onStart: (_) async {
          throw StateError('background unavailable');
        },
        onStop: () async {
          stops++;
        },
      );
      await q.add(
        cameraId: 'camera',
        files: [source()],
        destination: destination,
      );
      await expectLater(q.start(), throwsStateError);
      expect(stops, 1);
      expect(q.isRunning, false);
      expect(q.jobs.single.state, TransferState.queued);
      expect(adapter.calls, 0);
    },
  );

  test('cancellation cleanup failure cannot hang pause or retain background resources', () async {
    adapter.finish = false;
    adapter.limit = 2;
    adapter.cancellationFailure = StateError('session close failed');
    var stops = 0;
    final q = queue(
      onStop: () async {
        stops++;
      },
    );
    await q.add(
      cameraId: 'camera',
      files: [
        source(),
        source(id: 'two'),
      ],
      destination: destination,
    );
    final run = q.start();
    await until(() => q.jobs.first.bytesTransferred == 2);
    await q.pause().timeout(const Duration(seconds: 2));
    await run;
    expect(q.jobs.first.state, TransferState.failed);
    expect(q.jobs.first.lastError, contains('cancellation'));
    expect(q.jobs.last.state, TransferState.queued);
    expect(stops, 1);
  });

  test(
    'a verified full partial commits without requesting bytes again',
    () async {
      final q = queue();
      await q.add(
        cameraId: 'camera',
        files: [source()],
        destination: destination,
      );
      await q.close();
      final partial = File(q.jobs.single.temporaryPath!);
      await partial.parent.create(recursive: true);
      await partial.writeAsBytes(adapter.bytes);
      final stateFile = File('${state.path}/queue.json');
      final json =
          jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
      final job = (json['jobs'] as List).single as Map<String, dynamic>;
      job['state'] = 'copying';
      job['commitPending'] = true;
      job['checksum'] = sha256.convert(adapter.bytes).toString();
      await stateFile.writeAsString(jsonEncode(json));
      final reopened = queue();
      await reopened.ready;
      await reopened.start();
      expect(adapter.calls, 0);
      expect(reopened.jobs.single.state, TransferState.completed);
    },
  );

  test('a persisted checksum rejects a changed full partial', () async {
    final q = queue();
    await q.add(
      cameraId: 'camera',
      files: [source()],
      destination: destination,
    );
    await q.close();
    final partial = File(q.jobs.single.temporaryPath!);
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes([9, 9, 9, 9, 9, 9]);
    final stateFile = File('${state.path}/queue.json');
    final json =
        jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
    final job = (json['jobs'] as List).single as Map<String, dynamic>;
    job['state'] = 'copying';
    job['commitPending'] = true;
    job['checksum'] = sha256.convert(adapter.bytes).toString();
    await stateFile.writeAsString(jsonEncode(json));
    final reopened = queue();
    await reopened.ready;
    await reopened.start();
    expect(adapter.calls, 0);
    expect(reopened.jobs.single.state, TransferState.failed);
    expect(reopened.jobs.single.lastError, contains('checksum'));
    expect(await File(reopened.jobs.single.destinationPath).exists(), false);
  });

  test(
    'reopen reclaims only its own commit reservation before atomic rename',
    () async {
      final q = queue();
      await q.add(
        cameraId: 'camera',
        files: [source()],
        destination: destination,
      );
      await q.close();
      final partial = File(q.jobs.single.temporaryPath!);
      await partial.parent.create(recursive: true);
      await partial.writeAsBytes(adapter.bytes);
      final checksum = sha256.convert(adapter.bytes).toString();
      final stateFile = File('${state.path}/queue.json');
      final json =
          jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
      final job = (json['jobs'] as List).single as Map<String, dynamic>;
      job['state'] = 'copying';
      job['commitPending'] = true;
      job['checksum'] = checksum;
      await stateFile.writeAsString(jsonEncode(json));
      final originalPath = q.jobs.single.destinationPath;
      await File(originalPath).writeAsString(
        'camport-reservation-v1\n${q.jobs.single.id}\n$checksum\n',
      );
      final reopened = queue();
      await reopened.ready;
      await reopened.start();
      expect(reopened.jobs.single.destinationPath, originalPath);
      expect(await File(originalPath).readAsBytes(), adapter.bytes);
    },
  );

  test(
    'same-length binary collision is never interpreted as a reservation',
    () async {
      final q = queue();
      await q.add(
        cameraId: 'camera',
        files: [source()],
        destination: destination,
      );
      await q.close();
      final partial = File(q.jobs.single.temporaryPath!);
      await partial.parent.create(recursive: true);
      await partial.writeAsBytes(adapter.bytes);
      final checksum = sha256.convert(adapter.bytes).toString();
      final stateFile = File('${state.path}/queue.json');
      final json =
          jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
      final job = (json['jobs'] as List).single as Map<String, dynamic>;
      job['state'] = 'copying';
      job['commitPending'] = true;
      job['checksum'] = checksum;
      await stateFile.writeAsString(jsonEncode(json));
      final originalPath = q.jobs.single.destinationPath;
      final length = utf8
          .encode('camport-reservation-v1\n${q.jobs.single.id}\n$checksum\n')
          .length;
      final existing = List<int>.filled(length, 255);
      await File(originalPath).writeAsBytes(existing);
      final reopened = queue();
      await reopened.ready;
      await reopened.start();
      expect(reopened.jobs.single.state, TransferState.completed);
      expect(reopened.jobs.single.destinationPath, isNot(originalPath));
      expect(await File(originalPath).readAsBytes(), existing);
    },
  );

  test(
    'unsafe filename in valid JSON recovers backup instead of traversing',
    () async {
      final q = queue();
      await q.add(
        cameraId: 'camera',
        files: [source()],
        destination: destination,
      );
      await q.close();
      final stateFile = File('${state.path}/queue.json');
      final json =
          jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
      ((json['jobs'] as List).single as Map)['fileName'] = '../escape.ARW';
      await stateFile.writeAsString(jsonEncode(json));
      final reopened = queue();
      await reopened.ready;
      expect(reopened.recoveryWarning, isNotNull);
      await reopened.start();
      expect(reopened.jobs.single.state, TransferState.completed);
      expect(
        File(reopened.jobs.single.destinationPath).parent.path,
        destination.path,
      );
      expect(await File('${root.path}/escape.ARW').exists(), false);
    },
  );

  test(
    'close aborts the active download and persists intent for next process',
    () async {
      adapter.finish = false;
      adapter.limit = 2;
      final q = queue();
      await q.add(
        cameraId: 'camera',
        files: [
          source(),
          source(id: 'two'),
        ],
        destination: destination,
      );
      final run = q.start();
      await until(() => q.jobs.first.bytesTransferred == 2);
      await q.close();
      await run;
      expect(adapter.cancellations, 1);
      adapter = ControlledAdapter();
      final reopened = queue();
      await reopened.ready;
      expect(reopened.jobs.first.state, TransferState.interrupted);
      expect(reopened.jobs.last.state, TransferState.queued);
      await reopened.start();
      expect(adapter.offsets, [2, 0]);
      expect(
        reopened.jobs.every((j) => j.state == TransferState.completed),
        true,
      );
    },
  );
}
