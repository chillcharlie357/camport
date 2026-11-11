import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sony_camera/data/local/gallery_preferences.dart';
import 'package:sony_camera/domain/models/camera_file.dart';
import 'package:sony_camera/domain/models/camera_page.dart';
import 'package:sony_camera/features/gallery/gallery_controller.dart';

import 'gallery_test.dart' show MemoryStore, ListingAdapter, file;

class PagingAdapter extends ListingAdapter {
  PagingAdapter() : super([file('raw', 'DSC_1.ARW')]);
  final requests = <String?>[];
  Completer<CameraPage<CameraFile>>? gate;
  @override
  Future<CameraPage<CameraFile>> listFiles({String? cursor}) async {
    requests.add(cursor);
    if (cursor == null) return CameraPage(items: files, nextCursor: 'next');
    return gate?.future ??
        Future.value(CameraPage(items: [file('jpg', 'DSC_1.JPG')]));
  }
}

void main() {
  Future<GalleryController> open(PagingAdapter adapter) async {
    final prefs = GalleryPreferences(store: MemoryStore());
    await prefs.ready;
    prefs.setMergeRawJpeg(true);
    final controller = GalleryController(adapter: adapter, preferences: prefs);
    addTearDown(controller.dispose);
    addTearDown(prefs.dispose);
    await Future<void>.delayed(Duration.zero);
    return controller;
  }

  test(
    'pagination preserves physical selection as same-name pairs arrive',
    () async {
      final adapter = PagingAdapter();
      final controller = await open(adapter);
      expect(controller.hasMore, isTrue);
      controller.toggleEntrySelection(controller.visibleEntries.first);
      await controller.loadMoreFiles();
      expect(controller.hasMore, isFalse);
      expect(controller.visibleEntries, hasLength(1));
      expect(controller.visibleEntries.first.members, hasLength(2));
      expect(controller.selectionFor(controller.visibleEntries.first), isNull);
      expect(controller.selectedFiles.map((f) => f.id), ['raw']);
      expect(adapter.requests, [null, 'next']);
    },
  );

  test(
    'overlapping page requests deduplicate; refresh ignores late old pages',
    () async {
      final adapter = PagingAdapter()..gate = Completer();
      final controller = await open(adapter);
      final old = controller.loadMoreFiles();
      await controller.loadMoreFiles();
      expect(adapter.requests.where((c) => c == 'next'), hasLength(1));
      await controller.loadFiles();
      adapter.gate!.complete(CameraPage(items: [file('stale', 'OLD.JPG')]));
      await old;
      expect(controller.visibleFiles.map((f) => f.id), ['raw']);
      expect(controller.isLoadingMore, isFalse);
    },
  );
}
