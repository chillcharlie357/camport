import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sony_camera/data/adapters/fixture_camera_adapter.dart';
import 'package:sony_camera/data/local/gallery_preferences.dart';
import 'package:sony_camera/domain/models/camera_file.dart';
import 'package:sony_camera/domain/models/camera_page.dart';
import 'package:sony_camera/domain/ports/camera_adapter.dart';
import 'package:sony_camera/features/gallery/gallery_controller.dart';

class MemoryStore implements GalleryPreferenceStore {
  String? value;
  Completer<String?>? readGate;
  Completer<void>? writeGate;
  int activeWrites = 0;
  int maxActiveWrites = 0;
  bool failRead = false;
  bool failWrite = false;

  @override
  Future<String?> read() async {
    if (failRead) throw StateError('read unavailable');
    return readGate == null ? value : readGate!.future;
  }

  @override
  Future<void> write(String next) async {
    activeWrites++;
    if (activeWrites > maxActiveWrites) maxActiveWrites = activeWrites;
    try {
      if (writeGate != null) await writeGate!.future;
      if (failWrite) throw StateError('write unavailable');
      value = next;
    } finally {
      activeWrites--;
    }
  }
}

class ListingAdapter implements CameraAdapter {
  ListingAdapter(this.files);
  final List<CameraFile> files;
  @override
  Future<CameraPage<CameraFile>> listFiles({String? cursor}) async =>
      CameraPage(items: files);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CameraFile file(String id, String name) => CameraFile(
  id: id,
  name: name,
  extension: name.split('.').last,
  format: CameraFileFormat.fromFileName(name),
  byteLength: 100,
);

Future<GalleryController> gallery({
  List<CameraFile>? files,
  GalleryPreferences? preferences,
}) async {
  final prefs = preferences ?? GalleryPreferences(store: MemoryStore());
  if (preferences == null) {
    addTearDown(prefs.dispose);
    prefs.setMergeRawJpeg(true);
  }
  final controller = GalleryController(
    adapter: files == null ? FixtureCameraAdapter() : ListingAdapter(files),
    preferences: prefs,
  );
  addTearDown(controller.dispose);
  await prefs.ready;
  await controller.loadFiles();
  return controller;
}

void main() {
  test('merge defaults off until the user opts in', () async {
    final prefs = GalleryPreferences(store: MemoryStore());
    addTearDown(prefs.dispose);
    await prefs.ready;
    final controller = await gallery(preferences: prefs);
    expect(prefs.mergeRawJpeg, isFalse);
    expect(controller.visibleEntries, hasLength(24));
  });
  test(
    'fixture has six RAW/raster pairs, eight JPEG-only photos, four videos',
    () async {
      final controller = await gallery();
      expect(controller.visibleFiles, hasLength(24));
      expect(
        controller.filters
            .firstWhere((f) => f.format == CameraFileFormat.jpeg)
            .count,
        13,
      );
      expect(
        controller.filters
            .firstWhere((f) => f.format == CameraFileFormat.png)
            .count,
        1,
      );
      expect(controller.visibleEntries, hasLength(18));
      expect(
        controller.visibleEntries.where((e) => e.members.length == 2),
        hasLength(6),
      );
      expect(
        controller.visibleEntries.where((e) => !e.isPhotoEntry),
        hasLength(4),
      );
      controller.setMergeRawJpeg(false);
      expect(controller.visibleEntries, hasLength(24));
    },
  );

  test('case-insensitive basename groups RAW with JPEG and PNG; directory scopes it', () async {
    final controller = await gallery(
      files: [
        file('raw', 'A/Scene.01.ARW'),
        file('jpg', 'A/scene.01.JpEg'),
        file('png', 'A/SCENE.01.PNG'),
        file('other-dir', 'B/scene.01.JPG'),
        file('video', 'A/scene.01.MP4'),
        file('other-name', 'A/scene.02.JPG'),
      ],
    );
    expect(controller.visibleEntries, hasLength(4));
    final merged = controller.visibleEntries.first;
    expect(merged.members.map((f) => f.id), ['raw', 'jpg', 'png']);
    expect(merged.formatLabel, 'RAW + JPEG + PNG');
    expect(() => merged.members.clear(), throwsUnsupportedError);
    expect(() => controller.visibleEntries.clear(), throwsUnsupportedError);
  });

  test(
    'raster-only names and missing basenames remain separate entries',
    () async {
      final controller = await gallery(
        files: [
          file('jpg', 'photo.jpg'),
          file('png', 'photo.png'),
          file('raw1', '.arw'),
          file('raw2', '.arw'),
        ],
      );
      expect(controller.visibleEntries, hasLength(4));
      expect(
        controller.visibleEntries[2].identity,
        isNot(controller.visibleEntries[3].identity),
      );
    },
  );

  test('format filtering precedes merging and selection contains only physical RAW files', () async {
    final controller = await gallery();
    controller.selectFormat(CameraFileFormat.raw);
    expect(controller.visibleEntries, hasLength(6));
    for (final entry in controller.visibleEntries) {
      expect(entry.members.single.format, CameraFileFormat.raw);
      controller.toggleEntrySelection(entry);
    }
    expect(controller.selectedCount, 6);
    expect(
      controller.selectedFiles.every((f) => f.format == CameraFileFormat.raw),
      isTrue,
    );
    controller.selectFormat(null);
    expect(controller.selectionFor(controller.visibleEntries.first), isNull);
    expect(controller.selectedCount, 6);
  });

  test(
    'selection survives split/merge/filter; mixed toggles all then clears all',
    () async {
      final controller = await gallery();
      controller.setMergeRawJpeg(false);
      controller.toggleEntrySelection(controller.visibleEntries.first);
      final selected = controller.selectedFileIds;
      controller.setMergeRawJpeg(true);
      final entry = controller.visibleEntries.first;
      expect(controller.selectedFileIds, selected);
      expect(controller.selectionFor(entry), isNull);
      controller.selectFormat(CameraFileFormat.mp4);
      expect(controller.selectedFileIds, selected);
      controller.selectFormat(null);
      controller.toggleEntrySelection(entry);
      expect(controller.selectionFor(entry), isTrue);
      expect(controller.selectedCount, 2);
      controller.toggleEntrySelection(entry);
      expect(controller.selectionFor(entry), isFalse);
      expect(controller.selectedCount, 0);
    },
  );

  test(
    'split RAW/JPEG/PNG share rating through filter and merge changes',
    () async {
      final controller = await gallery(
        files: [
          file('raw', 'a.ARW'),
          file('jpg', 'A.jpg'),
          file('png', 'a.PNG'),
          file('unrelated', 'B.jpg'),
          file('video', 'a.mp4'),
        ],
      );
      controller.setMergeRawJpeg(false);
      controller.setRating(controller.visibleEntries.first, 4);
      expect(controller.visibleEntries.take(3).map(controller.ratingFor), [
        4,
        4,
        4,
      ]);
      expect(controller.ratingFor(controller.visibleEntries[3]), 0);
      controller.selectFormat(CameraFileFormat.png);
      expect(controller.visibleEntries.single.members.single.id, 'png');
      expect(controller.ratingFor(controller.visibleEntries.single), 4);
      expect(
        controller.membersFor(controller.visibleEntries.single),
        hasLength(3),
      );
      controller.setRating(controller.visibleEntries.single, 0);
      controller.selectFormat(null);
      controller.setMergeRawJpeg(true);
      expect(controller.ratingFor(controller.visibleEntries.first), 0);
      final video = controller.visibleEntries.last;
      controller.setRating(video, 5);
      expect(controller.ratingFor(video), 0);
    },
  );

  test(
    'ratings and merge preference survive a new repository and gallery',
    () async {
      final store = MemoryStore();
      final prefs = GalleryPreferences(store: store);
      addTearDown(prefs.dispose);
      final first = await gallery(preferences: prefs);
      first.setRating(first.visibleEntries.first, 5);
      first.setMergeRawJpeg(false);
      await prefs.flush();
      final restored = GalleryPreferences(store: store);
      addTearDown(restored.dispose);
      final next = await gallery(preferences: restored);
      expect(next.mergeRawJpeg, isFalse);
      expect(next.ratingFor(next.visibleEntries.first), 5);
      next.selectFormat(CameraFileFormat.jpeg);
      expect(next.ratingFor(next.visibleEntries.first), 5);
    },
  );

  test('in-flight load preserves user edits and retains untouched stored ratings', () async {
    final store = MemoryStore()..readGate = Completer<String?>();
    final prefs = GalleryPreferences(store: store);
    addTearDown(prefs.dispose);
    prefs.setRating('edited', 0);
    prefs.setMergeRawJpeg(true);
    store.readGate!.complete(
      '{"version":1,"mergeRawJpeg":false,"ratings":{"edited":5,"untouched":3}}',
    );
    await prefs.ready;
    await prefs.flush();
    expect(prefs.rating('edited'), 0);
    expect(prefs.rating('untouched'), 3);
    expect(prefs.mergeRawJpeg, isTrue);
    store.readGate = null;
    final restored = GalleryPreferences(store: store);
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.rating('edited'), 0);
    expect(restored.rating('untouched'), 3);
  });

  test(
    'writes serialize and reopening the gallery shares pending latest edits',
    () async {
      final store = MemoryStore()..writeGate = Completer<void>();
      final prefs = GalleryPreferences(store: store);
      addTearDown(prefs.dispose);
      final first = await gallery(preferences: prefs);
      first.setRating(first.visibleEntries.first, 1);
      await Future<void>.delayed(Duration.zero);
      final next = await gallery(preferences: prefs);
      next.setRating(next.visibleEntries.first, 5);
      next.setMergeRawJpeg(false);
      expect(first.ratingFor(first.visibleEntries.first), 5);
      store.writeGate!.complete();
      await prefs.flush();
      expect(store.maxActiveWrites, 1);
      final restored = GalleryPreferences(store: store);
      addTearDown(restored.dispose);
      await restored.ready;
      expect(restored.rating(next.visibleEntries.first.identity), 5);
      expect(restored.mergeRawJpeg, isFalse);
    },
  );

  test(
    'invalid persisted data is ignored without losing valid ratings',
    () async {
      for (final raw in [
        'bad json',
        '[]',
        '{"version":99}',
        '{"version":1,"mergeRawJpeg":"wrong","ratings":{"valid":4,"float":2.5,"high":6,"negative":-1,"bool":true}}',
      ]) {
        final prefs = GalleryPreferences(store: MemoryStore()..value = raw);
        addTearDown(prefs.dispose);
        await prefs.ready;
        expect(prefs.error, isNull);
        expect(prefs.mergeRawJpeg, isFalse);
        expect(prefs.rating('high'), 0);
        expect(prefs.rating('negative'), 0);
        expect(prefs.rating('float'), 0);
        expect(prefs.rating('bool'), 0);
        if (raw.contains('valid')) expect(prefs.rating('valid'), 4);
        expect(() => prefs.setRating('a', 6), throwsRangeError);
      }
    },
  );

  test(
    'failed reads do not overwrite stored data; retry saves local edits',
    () async {
      final store = MemoryStore()
        ..failRead = true
        ..value = '{"version":1,"ratings":{"old":3}}';
      final prefs = GalleryPreferences(store: store);
      addTearDown(prefs.dispose);
      prefs.setRating('new', 5);
      await prefs.ready;
      await prefs.flush();
      expect(prefs.error, isNotNull);
      expect(store.value, contains('old'));
      store.failRead = false;
      await prefs.retry();
      expect(prefs.error, isNull);
      expect(prefs.rating('old'), 3);
      expect(store.value, contains('new'));
    },
  );

  test('write failure is visible and recoverable', () async {
    final store = MemoryStore()..failWrite = true;
    final prefs = GalleryPreferences(store: store);
    addTearDown(prefs.dispose);
    await prefs.ready;
    prefs.setRating('a', 5);
    await prefs.flush();
    expect(prefs.error, isNotNull);
    store.failWrite = false;
    await prefs.retry();
    expect(prefs.error, isNull);
    expect(store.value, contains('"a":5'));
  });
}
