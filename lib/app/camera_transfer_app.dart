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
      title: 'Frame — Sony Camera Transfer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
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
                padding: EdgeInsets.fromLTRB(sideInset, 28, sideInset, 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _TopBar(),
                      SizedBox(height: isCompact ? 52 : 88),
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
                      const SizedBox(height: 64),
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
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              border: Border.all(color: colors.primary, width: 1.5),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              Icons.camera_alt_outlined,
              color: colors.primary,
              size: 21,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'FRAME',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(letterSpacing: 2.4, fontWeight: FontWeight.w800),
            ),
            Text(
              'SONY CAMERA TRANSFER',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontSize: 9,
                letterSpacing: 1.15,
              ),
            ),
          ],
        ),
        const Spacer(),
        if (MediaQuery.sizeOf(context).width >= 480)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                '本地传输',
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
        Row(
          children: [
            Container(width: 26, height: 1, color: colors.primary),
            const SizedBox(width: 11),
            Text(
              'CAMERA / 01',
              style: textTheme.labelSmall?.copyWith(color: colors.primary),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text(
          '把原片带回来。',
          style: compact ? textTheme.headlineMedium : textTheme.displaySmall,
        ),
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 470),
          child: Text(
            '首版面向 ZV-E10。一代机的连接与导入正在接入；当前页面不会尝试连接相机。',
            style: textTheme.bodyLarge,
          ),
        ),
        const SizedBox(height: 36),
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
        padding: const EdgeInsets.all(20),
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
                      Text('Sony ZV-E10', style: textTheme.titleLarge),
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
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final compact = MediaQuery.sizeOf(context).width < 720;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 20 : 28),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border.all(color: AppTheme.line),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '导入方式',
            style: textTheme.labelSmall?.copyWith(color: colors.primary),
          ),
          const SizedBox(height: 17),
          Text('保留原始文件', style: textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('不缩小、不转码。导入前可以按格式筛选。', style: textTheme.bodyMedium),
          const SizedBox(height: 23),
          const Divider(height: 1),
          const SizedBox(height: 18),
          Text('首版目标格式', style: textTheme.bodySmall),
          const SizedBox(height: 12),
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _FormatTag(label: 'RAW'),
              _FormatTag(label: 'JPEG'),
              _FormatTag(label: 'MP4'),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.folder_outlined, size: 18, color: colors.primary),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '文件保存在你的设备上',
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FormatTag extends StatelessWidget {
  const _FormatTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label 文件',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: AppTheme.text, letterSpacing: 0.8),
        ),
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
        ExcludeSemantics(
          child: Icon(
            Icons.lock_outline,
            size: 16,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            '设计目标：本地 Wi-Fi 传输，不需要云端账号。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
