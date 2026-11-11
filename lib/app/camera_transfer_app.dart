import 'dart:async';

import 'package:flutter/material.dart';

import '../data/adapters/fixture_camera_adapter.dart';
import '../features/connection/connect_screen.dart';
import '../features/gallery/gallery_screen.dart';
import '../features/import_queue/import_queue_screen.dart';
import 'app_runtime.dart';
import 'app_theme.dart';

class CameraTransferApp extends StatefulWidget {
  const CameraTransferApp({this.runtimeFactory, super.key});

  /// The factory creates the runtime owned by this app widget, not by a route.
  final Future<AppRuntime> Function()? runtimeFactory;

  @override
  State<CameraTransferApp> createState() => _CameraTransferAppState();
}

class _CameraTransferAppState extends State<CameraTransferApp> {
  AppRuntime? _runtime;
  Object? _error;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    AppRuntime? created;
    try {
      created = await (widget.runtimeFactory ?? AppRuntime.open)();
      await created.ready;
      if (!mounted) {
        await _closeOwned(created);
        return;
      }
      setState(() => _runtime = created);
    } catch (error) {
      if (created != null) await _closeOwned(created);
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _closeOwned(AppRuntime runtime) async {
    try {
      await runtime.close();
    } catch (error, stack) {
      // dispose cannot return a Future. Observe cleanup failure explicitly.
      debugPrint('Camera runtime cleanup failed: $error\n$stack');
    }
  }

  @override
  void dispose() {
    final runtime = _runtime;
    _runtime = null;
    if (runtime != null) unawaited(_closeOwned(runtime));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sony 相机导入',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: _runtime != null
          ? _ConnectHome(runtime: _runtime!)
          : Scaffold(
              body: SafeArea(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_opening) ...[
                            const CircularProgressIndicator(),
                            const SizedBox(height: 20),
                            const Text('正在恢复连接记录与导入队列…'),
                          ] else ...[
                            const Icon(Icons.folder_off_outlined, size: 40),
                            const SizedBox(height: 20),
                            Text(
                              '初始化失败',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 12),
                            Text('$_error', textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            const Text('现有导入文件与队列记录会保留。请检查存储权限和可用空间后重试。'),
                            const SizedBox(height: 20),
                            FilledButton(
                              onPressed: _open,
                              child: const Text('重试初始化'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _ConnectHome extends StatelessWidget {
  const _ConnectHome({required this.runtime});

  final AppRuntime runtime;

  void _connect(BuildContext context) => Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => ConnectScreen(runtime: runtime)),
  );

  void _openQueue(BuildContext context) => Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => ImportQueueScreen(runtime: runtime)),
  );

  void _openFixtureGallery(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GalleryScreen(
          adapter: FixtureCameraAdapter(),
          cameraName: '本地示例 · 不会导入',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) => Scaffold(
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
                        _TopBar(onOpenQueue: () => _openQueue(context)),
                        SizedBox(height: isCompact ? 36 : 56),
                        if (isCompact)
                          _MainContent(
                            runtime: runtime,
                            onConnect: () => _connect(context),
                            onOpenPreview: () => _openFixtureGallery(context),
                          )
                        else
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                flex: 6,
                                child: _MainContent(
                                  runtime: runtime,
                                  onConnect: () => _connect(context),
                                  onOpenPreview: () =>
                                      _openFixtureGallery(context),
                                ),
                              ),
                              const SizedBox(width: 64),
                              const Expanded(
                                flex: 5,
                                child: _TransferProfile(),
                              ),
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
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onOpenQueue});

  final VoidCallback onOpenQueue;

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
        TextButton.icon(
          onPressed: onOpenQueue,
          icon: const Icon(Icons.downloading_outlined, size: 18),
          label: const Text('导入队列'),
        ),
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
    required this.runtime,
    required this.onConnect,
    required this.onOpenPreview,
  });

  final AppRuntime runtime;
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
          child: Text(
            '连接相机 Wi-Fi，浏览真实文件并导入原片。未完成的任务会保存在导入队列中。',
            style: textTheme.bodyLarge,
          ),
        ),
        const SizedBox(height: 24),
        _CameraCard(
          runtime: runtime,
          onConnect: onConnect,
          onOpenPreview: onOpenPreview,
        ),
      ],
    );
  }
}

class _CameraCard extends StatelessWidget {
  const _CameraCard({
    required this.runtime,
    required this.onConnect,
    required this.onOpenPreview,
  });

  final AppRuntime runtime;
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
                      Text(
                        runtime.profile?.displayName ?? 'ZV-E10',
                        style: textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text('一代机型 · Wi-Fi', style: textTheme.bodyMedium),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _ConnectionStatus(connected: runtime.connected),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onConnect,
                icon: const Icon(Icons.wifi_tethering_rounded, size: 19),
                label: Text(runtime.connected ? '管理连接与浏览图库' : '连接相机'),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: OutlinedButton.icon(
                onPressed: onOpenPreview,
                icon: const Icon(Icons.photo_library_outlined, size: 19),
                label: const Text('查看示例图库（不会导入）'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Semantics(
      label: connected ? '相机已连接' : '相机尚未连接',
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
            Icon(
              Icons.circle,
              size: 7,
              color: connected ? colors.primary : colors.onSurfaceVariant,
            ),
            const SizedBox(width: 7),
            Text(
              connected ? '已连接' : '未连接',
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
          Text('原文件导入，不缩小、不转码。', style: textTheme.bodyMedium),
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
            '通过 Smartphone Connect / Send to Smartphone 连接。相机原片和已完成的本地文件不会因取消任务而删除。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
