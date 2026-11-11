import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sony_camera/app/app_theme.dart';
import 'package:sony_camera/data/adapters/fixture_camera_adapter.dart';
import 'package:sony_camera/data/local/gallery_preferences.dart';
import 'package:sony_camera/features/gallery/gallery_screen.dart';
import 'package:sony_camera/domain/ports/camera_adapter.dart';

import 'gallery_test.dart' show MemoryStore, ListingAdapter;

Future<GalleryPreferences> openGallery(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  CameraAdapter? adapter,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final prefs = GalleryPreferences(store: MemoryStore());
  addTearDown(prefs.dispose);
  await prefs.ready;
  prefs.setMergeRawJpeg(true);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: GalleryScreen(
        adapter: adapter ?? FixtureCameraAdapter(),
        preferences: prefs,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return prefs;
}

Future<void> openFilters(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('筛选与显示'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'formats live under more menu; PNG filter shows only one physical file',
    (tester) async {
      await openGallery(tester);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('18 项 · 24 个文件'), findsOneWidget);
      await openFilters(tester);
      expect(find.text('合并显示同名文件'), findsOneWidget);
      expect(find.text('PNG'), findsOneWidget);
      await tester.tap(find.text('PNG'));
      await tester.tap(find.byTooltip('关闭筛选'));
      await tester.pumpAndSettle();
      expect(find.text('1 项 · 1 个文件'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('select-jpeg-6')));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 个文件'), findsOneWidget);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不会传输文件'), findsOneWidget);
    },
  );

  testWidgets(
    'tile tap previews members without selection or rating controls',
    (tester) async {
      await openGallery(tester);
      await tester.tap(find.byKey(const ValueKey('preview-raw-1')));
      await tester.pumpAndSettle();
      expect(find.text('照片评分'), findsNothing);
      expect(find.text('DSC_0001.ARW'), findsWidgets);
      expect(find.text('DSC_0001.JPG'), findsWidgets);
      expect(find.byTooltip('评分 4 星'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('已选 0 个文件'), findsOneWidget);
      await tester.longPress(find.byKey(const ValueKey('preview-raw-1')));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 个文件'), findsOneWidget);
    },
  );

  testWidgets('preview shares format settings with the gallery', (
    tester,
  ) async {
    await openGallery(tester);
    await tester.tap(find.byKey(const ValueKey('preview-raw-1')));
    await tester.pumpAndSettle();
    await openFilters(tester);
    await tester.tap(find.text('PNG'));
    await tester.tap(find.byTooltip('关闭筛选'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('1 项 · 1 个文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh removing active format keeps header safe', (
    tester,
  ) async {
    final adapter = ListingAdapter(List.of(FixtureCameraAdapter.files));
    await openGallery(tester, adapter: adapter);
    await openFilters(tester);
    await tester.tap(find.text('PNG'));
    await tester.tap(find.byTooltip('关闭筛选'));
    await tester.pumpAndSettle();
    adapter.files.clear();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新载入示例文件'));
    await tester.pumpAndSettle();
    expect(find.text('0 项 · 0 个文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('separate checkbox remains accessible and has 48px target', (
    tester,
  ) async {
    await openGallery(tester);
    final handle = tester.ensureSemantics();
    final target = find.byKey(const ValueKey('select-raw-1'));
    expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel(RegExp('选择.*DSC_0001')), findsOneWidget);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(find.text('已选 2 个文件'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('narrow screen and large text have no layout exceptions', (
    tester,
  ) async {
    await openGallery(tester, size: const Size(320, 740), textScale: 1.8);
    expect(tester.takeException(), isNull);
    await openFilters(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preview-raw-1')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
