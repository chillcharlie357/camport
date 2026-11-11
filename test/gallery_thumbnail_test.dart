import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sony_camera/domain/models/transfer_progress.dart';

import 'gallery_screen_test.dart' show openGallery;
import 'gallery_test.dart' show ListingAdapter, file;

class ThumbnailListingAdapter extends ListingAdapter {
  ThumbnailListingAdapter()
    : super(List.generate(100, (i) => file('$i', 'DSC_$i.JPG')));

  final requests = <String>[];
  var originalRequests = 0;

  @override
  Future<Uint8List?> loadThumbnail(String fileId) async {
    requests.add(fileId);
    // Flutter's transparent 1 px PNG fixture; no network or original media.
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAABmJLR0QA/wD/AP+gvaeTAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAB3RJTUUH5gMQFwcdLl4wmwAAAAtJREFUCNdjYAACAAAFAAHiJgWbAAAAAElFTkSuQmCC',
    );
  }

  @override
  Stream<TransferProgress> downloadOriginal(String id, String destination) {
    originalRequests++;
    throw StateError('Browsing must not download originals');
  }
}

void main() {
  testWidgets('viewport requests only visible thumbnails plus one row', (
    tester,
  ) async {
    final adapter = ThumbnailListingAdapter();
    await openGallery(tester, adapter: adapter);
    expect(adapter.requests, isNotEmpty);
    expect(adapter.requests.length, lessThanOrEqualTo(8));
    expect(adapter.requests.toSet().length, adapter.requests.length);
    expect(adapter.originalRequests, 0);
    expect(find.byType(Image), findsWidgets);

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    final initial = List<String>.of(adapter.requests);
    position.jumpTo(6000);
    await tester.pumpAndSettle();
    final later = adapter.requests.skip(initial.length);
    expect(later, isNotEmpty);
    expect(later.every((id) => int.parse(id) > 20), isTrue);
    expect(later.length, lessThanOrEqualTo(8));

    position.jumpTo(0);
    await tester.pumpAndSettle();
    for (final id in initial) {
      expect(adapter.requests.where((r) => r == id), hasLength(1));
    }
    expect(adapter.originalRequests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single-photo preview reuses the gallery thumbnail', (
    tester,
  ) async {
    final adapter = ThumbnailListingAdapter();
    await openGallery(tester, adapter: adapter);
    final before = adapter.requests.length;
    await tester.tap(find.byKey(const ValueKey('preview-0')));
    await tester.pumpAndSettle();
    expect(adapter.requests.length, before);
    expect(find.text('缩略图预览'), findsOneWidget);
    expect(adapter.originalRequests, 0);
    expect(tester.takeException(), isNull);
  });
}
