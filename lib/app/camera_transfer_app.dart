import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/adapters/fixture_camera_adapter.dart';
import '../features/gallery/gallery_screen.dart';
import 'app_theme.dart';

class CameraTransferApp extends StatelessWidget {
  const CameraTransferApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sony 相机导入',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const _ConnectHome(),
    );
  }
}

class _ConnectHome extends StatelessWidget {
  const _ConnectHome();

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  String get _platformName => switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.windows => 'Windows',
    _ => '此平台',
  };

  void _showConnectStatus(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Android 连接流程尚未接入；此操作没有尝试连接相机。'),
          duration: Duration(seconds: 3),
        ),
      );
  }

  void _openFixtureGallery(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GalleryScreen(adapter: FixtureCameraAdapter()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 720;
            final sideInset = switch (constraints.maxWidth) {
              < 440 => 24.0,
              < 900 => 36.0,
              _ => 56.0,
            };

            return Align(
              alignment: Alignment.topCenter,
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(sideInset, 20, sideInset, 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _TopBar(),
                      SizedBox(height: isCompact ? 36 : 56),
                      if (isCompact)
                        _MainContent(
                          isAndroid: _isAndroid,
                          platformName: _platformName,
                          onConnect: () => _showConnectStatus(context),
                          onOpenPreview: () => _openFixtureGallery(context),
                        )
                      else
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              flex: 6,
                              child: _MainContent(
                                isAndroid: _isAndroid,
                                platformName: _platformName,
                                onConnect: () => _showConnectStatus(context),
                                onOpenPreview: () =>
                                    _openFixtureGallery(context),
                              ),
                            ),
                            const SizedBox(width: 64),
                            const Expanded(flex: 5, child: _TransferProfile()),
                          ],
                        ),
                      if (isCompact) ...[
                        const SizedBox(height: 36),
                        const _TransferProfile(),
                      ],
                      const SizedBox(height: 40),
                      const _Footer(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Row(
      children: [
        ExcludeSemantics(
          child: Icon(Icons.photo_camera_outlined, color: colors.primary),
        ),
        const SizedBox(width: 10),
        Text('相机导入', style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        if (MediaQuery.sizeOf(context).width >= 480)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Sony 相机',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
      ],
    );
  }
}

class _MainContent extends StatelessWidget {
  const _MainContent({
    required this.isAndroid,
    required this.platformName,
    required this.onConnect,
    required this.onOpenPreview,
  });

  final bool isAndroid;
  final String platformName;
  final VoidCallback onConnect;
  final VoidCallback onOpenPreview;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final compact = MediaQuery.sizeOf(context).width < 720;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Sony ZV-E10',
          style: textTheme.labelLarge?.copyWith(color: colors.primary),
        ),
        const SizedBox(height: 12),
        Text(
          '导入相机照片',
          style: compact ? textTheme.headlineMedium : textTheme.displaySmall,
        ),
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 470),
          child: Text('相机连接功能仍在开发中。可先查看示例文件和格式筛选。', style: textTheme.bodyLarge),
        ),
        const SizedBox(height: 24),
        _CameraCard(
          isAndroid: isAndroid,
          platformName: platformName,
          onConnect: onConnect,
          onOpenPreview: onOpenPreview,
        ),
      ],
    );
  }
}

class _CameraCard extends StatelessWidget {
  const _CameraCard({
    required this.isAndroid,
    required this.platformName,
    required this.onConnect,
    required this.onOpenPreview,
  });

  final bool isAndroid;
  final String platformName;
  final VoidCallback onConnect;
  final VoidCallback onOpenPreview;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppTheme.raisedSurface,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(
                      Icons.photo_camera_outlined,
                      color: colors.onSurface,
                      size: 23,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ZV-E10', style: textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text('一代机型 · Wi-Fi', style: textTheme.bodyMedium),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const _ConnectionStatus(),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: isAndroid ? onConnect : null,
                icon: const Icon(Icons.wifi_tethering_rounded, size: 19),
                label: Text(isAndroid ? '连接相机' : '连接功能未配置'),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: OutlinedButton.icon(
                onPressed: onOpenPreview,
                icon: const Icon(Icons.photo_library_outlined, size: 19),
                label: const Text('预览本地示例图库'),
              ),
            ),
            if (!isAndroid) ...[
              const SizedBox(height: 12),
              Text(
                '$platformName 的相机连接尚未配置。',
                style: textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Semantics(
      label: '相机尚未连接',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: AppTheme.raisedSurface,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: AppTheme.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 7, color: colors.onSurfaceVariant),
            const SizedBox(width: 7),
            Text(
              '未连接',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: colors.onSurfaceVariant, letterSpacing: 0),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransferProfile extends StatelessWidget {
  const _TransferProfile();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final compact = MediaQuery.sizeOf(context).width < 720;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 18 : 22),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border.all(color: AppTheme.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('支持的文件', style: textTheme.titleLarge),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 4),
          _FormatLine(label: '照片', formats: 'RAW  ·  JPEG'),
          const Divider(height: 1),
          _FormatLine(label: '视频', formats: 'MP4  ·  MTS'),
          const Divider(height: 1),
          const SizedBox(height: 14),
          Text('目标：原文件导入，不缩小、不转码。', style: textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _FormatLine extends StatelessWidget {
  const _FormatLine({required this.label, required this.formats});

  final String label;
  final String formats;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label：$formats',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final largeText = MediaQuery.textScalerOf(context).scale(16) >= 20;
          if (constraints.maxWidth < 300 || largeText) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 4),
                  Text(formats, style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            );
          }

          return SizedBox(
            height: 48,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Text(formats, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Row(
      children: [
        Expanded(
          child: Text(
            '当前为示例界面；连接相机后会显示实际文件。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
