import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:camport/domain/models/camera_file.dart';
import 'package:camport/domain/models/transfer_progress.dart';
import 'package:camport/domain/ports/camera_adapter.dart';
import 'package:camport/features/gallery/thumbnail_repository.dart';

class ControlledAdapter implements CameraAdapter {
  final calls = <String>[];
  final pending = <String, List<Completer<Uint8List?>>>{};
  int active = 0;
  int peakActive = 0;
  int originalCalls = 0;
  bool throwSynchronously = false;

  @override
  Future<Uint8List?> loadThumbnail(String fileId) {
    calls.add(fileId);
    if (throwSynchronously) throw StateError('synchronous adapter failure');
    final completer = Completer<Uint8List?>();
    pending.putIfAbsent(fileId, () => []).add(completer);
    active++;
    if (active > peakActive) peakActive = active;
    return completer.future.whenComplete(() => active--);
  }

  void complete(String id, [Uint8List? bytes]) =>
      pending[id]!.removeAt(0).complete(bytes);

  void fail(String id, Object error) =>
      pending[id]!.removeAt(0).completeError(error);

  @override
  Stream<TransferProgress> downloadOriginal(String id, String destination) {
    originalCalls++;
    throw StateError('Originals must never be requested');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CameraFile photo(
  String id, {
  String? thumbnailKey,
  int byteLength = 100,
  DateTime? capturedAt,
}) => CameraFile(
  id: id,
  name: '$id.JPG',
  extension: 'JPG',
  format: CameraFileFormat.jpeg,
  byteLength: byteLength,
  capturedAt: capturedAt,
  thumbnailKey: thumbnailKey,
);

Uint8List data(int value, [int length = 2]) =>
    Uint8List.fromList(List.filled(length, value));

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late ControlledAdapter adapter;
  late ThumbnailRepository repository;

  ThumbnailRepository create({
    int concurrency = 2,
    int budget = 32 * 1024 * 1024,
  }) {
    final result = ThumbnailRepository(
      adapter: adapter,
      namespace: 'camera/card-A',
      maxConcurrent: concurrency,
      maxMemoryBytes: budget,
    );
    addTearDown(result.dispose);
    return result;
  }

  setUp(() {
    adapter = ControlledAdapter();
    repository = create();
    addTearDown(() => expect(adapter.originalCalls, 0));
  });

  test(
    'explicit retry replaces cached bytes rejected by the image decoder',
    () async {
      final file = photo('corrupt');
      final first = repository.loadForPreview(file);
      adapter.complete(file.id, data(1));
      await first;
      repository.retry(file);
      repository.retry(file);
      expect(adapter.calls, ['corrupt', 'corrupt']);
      expect(repository.stateFor(file).status, ThumbnailStatus.loading);
      adapter.complete(file.id, data(2));
      await settle();
      expect(repository.stateFor(file).bytes, data(2));
    },
  );

  test(
    'idle reads do not fetch; visible wins and duplicates share two slots',
    () async {
      final a = photo('a');
      final b = photo('b');
      final c = photo('c');
      final p = photo('prefetch');
      expect(repository.stateFor(a).status, ThumbnailStatus.idle);
      expect(adapter.calls, isEmpty);
      repository.setViewport(visible: [a, a, b, c], prefetch: [p, a, p]);
      expect(adapter.calls, ['a', 'b']);
      expect(repository.stateFor(a).status, ThumbnailStatus.loading);
      expect(repository.stateFor(c).status, ThumbnailStatus.queued);
      adapter.complete('a', data(1));
      await settle();
      expect(adapter.calls, ['a', 'b', 'c']);
      adapter.complete('b', data(2));
      await settle();
      expect(adapter.calls, ['a', 'b', 'c', 'prefetch']);
      adapter.complete('c', data(3));
      adapter.complete('prefetch', data(4));
      await settle();
      repository.setViewport(visible: [a, b, c], prefetch: [p]);
      expect(adapter.calls, hasLength(4));
      expect(adapter.peakActive, 2);
      expect(repository.stateFor(a).bytes, data(1));
    },
  );

  test(
    'replaces old queued work and keeps uncancellable requests in the limit',
    () async {
      repository = create(concurrency: 1);
      final a = photo('a');
      final removed = photo('removed');
      final oldPrefetch = photo('old-prefetch');
      final next = photo('next');
      repository.setViewport(visible: [a, removed], prefetch: [oldPrefetch]);
      await settle();
      var notifications = 0;
      repository.addListener(() => notifications++);
      repository.setViewport(visible: [next]);
      await settle();
      expect(repository.stateFor(removed).status, ThumbnailStatus.idle);
      expect(repository.stateFor(oldPrefetch).status, ThumbnailStatus.idle);
      expect(repository.stateFor(a).status, ThumbnailStatus.loading);
      expect(notifications, 1);
      expect(adapter.calls, ['a']);
      adapter.complete('a', data(1));
      await settle();
      expect(adapter.calls, ['a', 'next']);
      expect(adapter.peakActive, 1);
      adapter.complete('next', data(2));
      await settle();
      expect(repository.stateFor(next).status, ThumbnailStatus.ready);
    },
  );

  test('viewport order reprioritizes already queued visible files', () async {
    repository = create(concurrency: 1);
    final a = photo('a');
    final b = photo('b');
    final c = photo('c');
    repository.setViewport(visible: [a, b, c]);
    repository.setViewport(visible: [c, b]);
    adapter.complete('a');
    await settle();
    expect(adapter.calls, ['a', 'c']);
  });

  test('preview promotes queued work, survives scrolling and shares in-flight/cache', () async {
    repository = create(concurrency: 1);
    final a = photo('a');
    final b = photo('b');
    final p = photo('p');
    repository.setViewport(visible: [a, b], prefetch: [p]);
    final first = repository.loadForPreview(p);
    final second = repository.loadForPreview(p);
    repository.setViewport(visible: [b]);
    adapter.complete('a', data(1));
    await settle();
    expect(adapter.calls, ['a', 'p']);
    final third = repository.loadForPreview(p);
    adapter.complete('p', data(3));
    expect(await first, data(3));
    expect(await second, data(3));
    expect(await third, data(3));
    expect(await repository.loadForPreview(p), data(3));
    expect(adapter.calls.where((id) => id == 'p'), hasLength(1));
    expect(adapter.calls, ['a', 'p', 'b']);
  });

  test(
    'import pauses prefetch but allows visible and preview, then resumes',
    () async {
      repository = create(concurrency: 1);
      final a = photo('a');
      final b = photo('b');
      final p = photo('p');
      final q = photo('q');
      repository.setImportActive(true);
      repository.setViewport(visible: [a, b], prefetch: [p, q]);
      adapter.complete('a', data(1));
      await settle();
      expect(adapter.calls, ['a', 'b']);
      adapter.complete('b', data(2));
      await settle();
      expect(repository.stateFor(p).status, ThumbnailStatus.queued);
      expect(adapter.calls, ['a', 'b']);
      final preview = repository.loadForPreview(p);
      expect(adapter.calls, ['a', 'b', 'p']);
      adapter.complete('p', data(3));
      await preview;
      expect(adapter.calls, ['a', 'b', 'p']);
      repository.setImportActive(false);
      expect(adapter.calls, ['a', 'b', 'p', 'q']);
    },
  );

  test(
    'an import started during prefetch does not free its occupied slot',
    () async {
      repository = create(concurrency: 1);
      repository.setViewport(visible: [], prefetch: [photo('p'), photo('q')]);
      repository.setImportActive(true);
      repository.setViewport(
        visible: [photo('visible')],
        prefetch: [photo('q')],
      );
      expect(adapter.calls, ['p']);
      adapter.complete('p', data(1));
      await settle();
      expect(adapter.calls, ['p', 'visible']);
      adapter.complete('visible', data(2));
      await settle();
      expect(adapter.calls, ['p', 'visible']);
    },
  );

  test('import reduces visible and preview concurrency to one without cancelling active work', () async {
    final a = photo('a');
    final b = photo('b');
    final c = photo('c');
    final p = photo('preview');
    repository.setViewport(visible: [a, b, c]);
    expect(adapter.calls, ['a', 'b']);
    repository.setImportActive(true);
    final preview = repository.loadForPreview(p);
    adapter.complete('a', data(1));
    await settle();
    expect(adapter.active, 1);
    expect(adapter.calls, ['a', 'b']);
    adapter.complete('b', data(2));
    await settle();
    expect(adapter.active, 1);
    expect(adapter.calls, ['a', 'b', 'preview']);
    adapter.complete('preview', data(3));
    await preview;
    expect(adapter.active, 1);
    expect(adapter.calls, ['a', 'b', 'preview', 'c']);
    repository.setViewport(visible: [c, photo('d')]);
    expect(adapter.calls, ['a', 'b', 'preview', 'c']);
    repository.setImportActive(false);
    expect(adapter.calls, ['a', 'b', 'preview', 'c', 'd']);
  });

  test('null, empty and errors are terminal until an explicit retry', () async {
    for (final outcome in ['null', 'empty', 'error']) {
      final file = photo(outcome);
      final first = repository.loadForPreview(file);
      final failure = StateError('camera unavailable');
      if (outcome == 'error') {
        adapter.fail(file.id, failure);
      } else {
        adapter.complete(file.id, outcome == 'empty' ? Uint8List(0) : null);
      }
      expect(await first, isNull);
      final state = repository.stateFor(file);
      expect(
        state.status,
        outcome == 'error'
            ? ThumbnailStatus.error
            : ThumbnailStatus.unavailable,
      );
      expect(state.bytes, isNull);
      expect(state.error, outcome == 'error' ? same(failure) : isNull);
      repository.setViewport(visible: [file]);
      repository.setViewport(visible: []);
      repository.setViewport(visible: [file]);
      expect(await repository.loadForPreview(file), isNull);
      expect(adapter.calls.where((id) => id == file.id), hasLength(1));
      repository.retry(file);
      repository.retry(file);
      expect(adapter.calls.where((id) => id == file.id), hasLength(2));
      final retried = repository.loadForPreview(file);
      adapter.complete(file.id, data(7));
      expect(await retried, data(7));
      expect(repository.stateFor(file).error, isNull);
    }
  });

  test(
    'synchronous adapter errors are contained and release concurrency',
    () async {
      adapter.throwSynchronously = true;
      final file = photo('a');
      expect(await repository.loadForPreview(file), isNull);
      expect(repository.stateFor(file).status, ThumbnailStatus.error);
      adapter.throwSynchronously = false;
      repository.retry(file);
      final retried = repository.loadForPreview(file);
      adapter.complete('a', data(4));
      expect(await retried, data(4));
    },
  );

  test('byte budget evicts LRU and state reads refresh recency', () async {
    repository = create(budget: 4);
    final a = photo('a');
    final b = photo('b');
    final c = photo('c');
    for (final file in [a, b]) {
      final future = repository.loadForPreview(file);
      adapter.complete(file.id, data(1));
      await future;
    }
    expect(repository.stateFor(a).status, ThumbnailStatus.ready);
    final future = repository.loadForPreview(c);
    adapter.complete('c', data(2));
    await future;
    expect(repository.stateFor(b).status, ThumbnailStatus.idle);
    expect(repository.stateFor(a).bytes, data(1));
    expect(repository.stateFor(c).bytes, data(2));
    final reloaded = repository.loadForPreview(b);
    adapter.complete('b', data(3));
    expect(await reloaded, data(3));
    expect(adapter.calls, ['a', 'b', 'c', 'b']);
    expect(repository.stateFor(a).status, ThumbnailStatus.idle);
  });

  test(
    'rejects oversized entries without retrying or downloading originals',
    () async {
      final exact = photo('exact');
      final accepted = repository.loadForPreview(exact);
      adapter.complete('exact', Uint8List(2 * 1024 * 1024));
      expect(await accepted, hasLength(2 * 1024 * 1024));
      final large = photo('large');
      final rejected = repository.loadForPreview(large);
      adapter.complete('large', Uint8List(2 * 1024 * 1024 + 1));
      expect(await rejected, isNull);
      expect(repository.stateFor(large).status, ThumbnailStatus.unavailable);
      repository.setViewport(visible: [large]);
      expect(await repository.loadForPreview(large), isNull);
      expect(adapter.calls, ['exact', 'large']);
      expect(repository.stateFor(exact).status, ThumbnailStatus.ready);
    },
  );

  test(
    'a thumbnail larger than the total budget is not retained or refetched',
    () async {
      repository = create(budget: 2);
      final file = photo('a');
      final future = repository.loadForPreview(file);
      adapter.complete('a', data(1, 3));
      expect(await future, isNull);
      expect(repository.stateFor(file).status, ThumbnailStatus.unavailable);
      repository.setViewport(visible: [file]);
      expect(adapter.calls, ['a']);
    },
  );

  test(
    'cache owns exact immutable bytes rather than adapter buffer views',
    () async {
      final file = photo('a');
      final source = Uint8List(100)..[20] = 7;
      final result = repository.loadForPreview(file);
      adapter.complete('a', Uint8List.sublistView(source, 20, 22));
      final bytes = (await result)!;
      source[20] = 99;
      expect(bytes, [7, 0]);
      expect(bytes.buffer.lengthInBytes, 2);
      expect(() => bytes[0] = 12, throwsUnsupportedError);
      expect(repository.stateFor(file).bytes, [7, 0]);
    },
  );

  test('all identity metadata separates cache and late versions cannot replace new ones', () async {
    final variants = [
      photo('a'),
      photo('b'),
      photo('a', thumbnailKey: ''),
      photo('a', thumbnailKey: 'v2'),
      photo('a', byteLength: 101),
      photo('a', capturedAt: DateTime.utc(2026, 1, 1)),
      photo('a', capturedAt: DateTime.utc(2026, 1, 2)),
    ];
    for (var i = 0; i < variants.length; i++) {
      final future = repository.loadForPreview(variants[i]);
      adapter.complete(variants[i].id, data(i));
      expect(await future, data(i));
    }
    for (var i = 0; i < variants.length; i++) {
      expect(repository.stateFor(variants[i]).bytes, data(i));
    }
    final otherNamespace = ThumbnailRepository(
      adapter: adapter,
      namespace: 'camera/card-B',
    );
    addTearDown(otherNamespace.dispose);
    expect(
      otherNamespace.stateFor(variants.first).status,
      ThumbnailStatus.idle,
    );
    final other = otherNamespace.loadForPreview(variants.first);
    adapter.complete('a', data(9));
    expect(await other, data(9));
    expect(repository.stateFor(variants.first).bytes, data(0));

    final oldFile = photo('late', thumbnailKey: 'old');
    final newFile = photo('late', thumbnailKey: 'new');
    repository.setViewport(visible: [oldFile]);
    repository.setViewport(visible: [newFile]);
    // Resolve the new version before the uncancellable old request.
    adapter.pending['late']!.removeAt(1).complete(data(8));
    await settle();
    adapter.complete('late', data(7));
    await settle();
    expect(repository.stateFor(newFile).bytes, data(8));
    expect(repository.stateFor(oldFile).bytes, data(7));
  });

  test(
    'offscreen late completion caches silently and removed queues stay idle',
    () async {
      repository = create(concurrency: 1);
      final a = photo('a');
      final removed = photo('removed');
      repository.setViewport(visible: [a, removed]);
      repository.setViewport(visible: []);
      await settle();
      var notifications = 0;
      repository.addListener(() => notifications++);
      adapter.complete('a', data(1));
      await settle();
      expect(notifications, 0);
      expect(repository.stateFor(a).status, ThumbnailStatus.ready);
      expect(repository.stateFor(removed).status, ThumbnailStatus.idle);
      repository.setViewport(visible: [a]);
      expect(adapter.calls, ['a']);
    },
  );

  test('identical viewports do not emit redundant notifications', () async {
    final a = photo('a');
    repository.setViewport(visible: [a]);
    await settle();
    var notifications = 0;
    repository.addListener(() => notifications++);
    repository.setViewport(visible: [a, a], prefetch: [a]);
    await settle();
    expect(notifications, 0);
    adapter.complete('a', data(1));
    await settle();
    expect(notifications, 1);
  });

  test('dispose settles preview waiters and ignores late success/error and notifications', () async {
    final running = repository.loadForPreview(photo('a'));
    repository.setViewport(visible: [photo('b'), photo('c')]);
    final queued = repository.loadForPreview(photo('c'));
    var notifications = 0;
    repository.addListener(() => notifications++);
    repository.dispose();
    expect(await running, isNull);
    expect(await queued, isNull);
    adapter.complete('a', data(1));
    adapter.fail('b', StateError('late failure'));
    await settle();
    expect(notifications, 0);
    expect(adapter.calls, ['a', 'b']);
    expect(repository.stateFor(photo('a')).status, ThumbnailStatus.idle);
    repository.setViewport(visible: [photo('d')]);
    repository.setImportActive(false);
    repository.retry(photo('a'));
    expect(await repository.loadForPreview(photo('a')), isNull);
    expect(adapter.calls, ['a', 'b']);
  });

  test('listener may dispose during a queued notification', () async {
    repository.addListener(repository.dispose);
    repository.setViewport(visible: [photo('a'), photo('b'), photo('c')]);
    await settle();
    adapter.complete('a', data(1));
    adapter.complete('b', data(2));
    await settle();
    expect(adapter.calls, ['a', 'b']);
  });

  test(
    'validates concurrency in release mode and requires a positive budget',
    () {
      for (final limit in [-1, 0, 3, 20]) {
        expect(() => create(concurrency: limit), throwsArgumentError);
      }
      for (final budget in [-1, 0]) {
        expect(() => create(budget: budget), throwsArgumentError);
      }
    },
  );
}
