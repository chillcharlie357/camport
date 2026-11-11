import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sony_camera/data/local/thumbnail_disk_cache.dart';
import 'package:sony_camera/features/gallery/thumbnail_repository.dart';

import 'thumbnail_repository_test.dart' show ControlledAdapter, photo, data;

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 1000 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue);
}

void main() {
  test(
    'a new repository reuses persistent thumbnails without camera traffic',
    () async {
      final dir = await Directory.systemTemp.createTemp('thumbnail-reopen');
      addTearDown(() => dir.delete(recursive: true));
      final file = photo('a', thumbnailKey: 'revision-1');
      final firstCache = ThumbnailDiskCache(directory: dir);
      final firstAdapter = ControlledAdapter();
      final first = ThumbnailRepository(
        adapter: firstAdapter,
        namespace: 'camera/card',
        diskCache: firstCache,
      );
      final load = first.loadForPreview(file);
      await until(() => firstAdapter.calls.isNotEmpty);
      firstAdapter.complete('a', data(1));
      expect(await load, data(1));
      first.dispose();
      await firstCache.close();

      final nextCache = ThumbnailDiskCache(directory: dir);
      final nextAdapter = ControlledAdapter();
      final next = ThumbnailRepository(
        adapter: nextAdapter,
        namespace: 'camera/card',
        diskCache: nextCache,
      );
      addTearDown(next.dispose);
      addTearDown(nextCache.close);
      expect(await next.loadForPreview(file), data(1));
      expect(nextAdapter.calls, isEmpty);
      expect(nextAdapter.originalCalls, 0);

      final changed = next.loadForPreview(
        photo('a', thumbnailKey: 'revision-2'),
      );
      await until(() => nextAdapter.calls.isNotEmpty);
      nextAdapter.complete('a', data(2));
      expect(await changed, data(2));
    },
  );

  test(
    'retry evicts bad disk bytes and does not loop on the same cached image',
    () async {
      final dir = await Directory.systemTemp.createTemp('thumbnail-retry');
      addTearDown(() => dir.delete(recursive: true));
      final cache = ThumbnailDiskCache(directory: dir);
      addTearDown(cache.close);
      final adapter = ControlledAdapter();
      final repository = ThumbnailRepository(
        adapter: adapter,
        namespace: 'camera/card',
        diskCache: cache,
      );
      addTearDown(repository.dispose);
      final file = photo('a');
      final first = repository.loadForPreview(file);
      await until(() => adapter.calls.isNotEmpty);
      adapter.complete('a', data(1));
      await first;
      repository.retry(file);
      await until(() => adapter.calls.length == 2);
      adapter.complete('a', data(2));
      await until(
        () => repository.stateFor(file).status == ThumbnailStatus.ready,
      );
      expect(repository.stateFor(file).bytes, data(2));
      expect(adapter.originalCalls, 0);
    },
  );
}
