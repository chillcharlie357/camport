import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../app/app_theme.dart';
import '../../data/local/gallery_preferences.dart';
import '../../data/local/thumbnail_disk_cache.dart';
import '../../domain/models/camera_file.dart';
import '../../domain/ports/camera_adapter.dart';
import '../../domain/models/gallery_entry.dart';
import 'camera_file_tile.dart';
import 'format_filter_row.dart';
import 'gallery_controller.dart';
import 'photo_preview_screen.dart';
import 'thumbnail_repository.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({
    required this.adapter,
    this.preferences,
    this.cameraName,
    this.cameraId,
    this.diskCache,
    this.cacheNamespace,
    this.onImport,
    this.onOpenQueue,
    this.activity,
    this.isTransferring,
    this.isConnected,
    this.connectionEpoch,
    super.key,
  });

  final CameraAdapter adapter;
  final GalleryPreferences? preferences;
  final String? cameraName;
  final String? cameraId;
  final ThumbnailDiskCache? diskCache;
  final String? cacheNamespace;
  final Future<void> Function(List<CameraFile>)? onImport;
  final VoidCallback? onOpenQueue;
  final Listenable? activity;
  final bool Function()? isTransferring;
  final bool Function()? isConnected;
  final int Function()? connectionEpoch;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late final GalleryController _controller;
  late ThumbnailRepository _thumbnails;
  final _scroll = ScrollController();
  final _gridKey = GlobalKey();
  bool _viewportScheduled = false;
  bool _previewOpen = false;
  List<GalleryEntry> _renderedEntries = const [];
  bool _reloadAfterPreview = false;
  bool _importing = false;
  late int _epoch;
  late bool _connected;

  @override
  void initState() {
    super.initState();
    _controller = GalleryController(
      adapter: widget.adapter,
      cameraId: widget.cameraId,
      preferences: widget.preferences,
    );
    _thumbnails = _newThumbnails();
    _epoch = widget.connectionEpoch?.call() ?? 0;
    _connected = widget.isConnected?.call() ?? widget.cameraName != null;
    widget.activity?.addListener(_activityChanged);
    _controller.addListener(_scheduleViewport);
    _scroll.addListener(_scheduleViewport);
  }

  @override
  void dispose() {
    widget.activity?.removeListener(_activityChanged);
    _scroll.dispose();
    _thumbnails.dispose();
    _controller.removeListener(_scheduleViewport);
    _controller.dispose();
    super.dispose();
  }

  ThumbnailRepository _newThumbnails() => ThumbnailRepository(
    adapter: widget.adapter,
    namespace:
        widget.cacheNamespace ??
        'gallery:${DateTime.now().microsecondsSinceEpoch}',
    diskCache: widget.cacheNamespace == null ? null : widget.diskCache,
  )..setImportActive(widget.isTransferring?.call() ?? false);

  void _activityChanged() {
    if (!mounted) return;
    _thumbnails.setImportActive(widget.isTransferring?.call() ?? false);
    final epoch = widget.connectionEpoch?.call() ?? 0;
    if (epoch != _epoch) {
      _epoch = epoch;
      if (_previewOpen) {
        _reloadAfterPreview = true;
      } else {
        _refreshSession();
      }
    }
    final connected = widget.isConnected?.call() ?? widget.cameraName != null;
    if (connected != _connected) setState(() => _connected = connected);
  }

  void _refreshSession() {
    _thumbnails.dispose();
    _thumbnails = _newThumbnails();
    _controller.loadFiles();
  }

  Future<void> _clearThumbnailCache() async {
    await _thumbnails.clearCache();
    PaintingBinding.instance.imageCache.clear();
    _scheduleViewport();
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _importSelected() => _importFiles(_controller.selectedFiles);

  Future<void> _importFiles(List<CameraFile> files) async {
    final action = widget.onImport;
    if (action == null) {
      _showImportNotice();
      return;
    }
    if (_importing || files.isEmpty) return;
    setState(() => _importing = true);
    final counts = <CameraFileFormat, int>{};
    for (final file in files) {
      counts.update(file.format, (value) => value + 1, ifAbsent: () => 1);
    }
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('导入 ${files.length} 个原始文件？'),
          content: Text(
            counts.entries
                .map((item) => '${cameraFormatLabel(item.key)} ${item.value} 个')
                .join(' · '),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('加入导入队列'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      await action(files);
      if (!mounted) return;
      if (files.length == _controller.selectedCount &&
          files.every(_controller.isSelected)) {
        _controller.clearSelection();
      }
      widget.onOpenQueue?.call();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加入队列失败，选择已保留：$error')));
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _scheduleViewport() {
    if (_viewportScheduled || !mounted) return;
    _viewportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportScheduled = false;
      if (!mounted || _previewOpen) return;
      final render = _gridKey.currentContext?.findRenderObject();
      if (_controller.isLoading ||
          render is! RenderSliverGrid ||
          !render.attached ||
          render.geometry?.visible != true) {
        _thumbnails.setViewport(visible: const []);
        return;
      }
      final entries = _renderedEntries;
      final layout = render.gridDelegate.getLayout(render.constraints);
      // Use paint extent, not cache extent: Flutter builds offscreen tiles too.
      final start = layout
          .getMinChildIndexForScrollOffset(render.constraints.scrollOffset)
          .clamp(0, entries.length);
      final end =
          (layout.getMaxChildIndexForScrollOffset(
                    render.constraints.scrollOffset +
                        render.geometry!.paintExtent,
                  ) +
                  1)
              .clamp(start, entries.length);
      final columns =
          (render.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
              .crossAxisCount;
      final prefetchEnd = (end + columns).clamp(end, entries.length);
      _thumbnails.setViewport(
        visible: entries
            .sublist(start, end)
            .map((e) => e.representative)
            .toList(),
        prefetch: entries
            .sublist(end, prefetchEnd)
            .map((e) => e.representative)
            .toList(),
      );
      if (_controller.hasMore &&
          !_controller.isLoadingMore &&
          _controller.loadMoreError == null &&
          end >= entries.length - columns) {
        _controller.loadMoreFiles();
      }
    });
  }

  Future<void> _openPreview(GalleryEntry entry) async {
    _previewOpen = true;
    _thumbnails.setViewport(visible: const []);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PhotoPreviewScreen(
          entry: entry,
          controller: _controller,
          thumbnails: _thumbnails,
          isDemo: widget.cameraName == null,
          onImport: widget.onImport == null ? null : _importFiles,
        ),
      ),
    );
    if (!mounted) return;
    _previewOpen = false;
    if (_reloadAfterPreview) {
      _reloadAfterPreview = false;
      _refreshSession();
    }
    _scheduleViewport();
    // A post-frame callback alone doesn't schedule a frame after pop settles.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _showImportNotice() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('相机集成完成后可导入；此示例图库不会传输文件。'),
          duration: Duration(seconds: 3),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        // Filtering/grouping runs when gallery data changes, not on every pixel
        // of scrolling. The viewport uses the same snapshot as the grid.
        _renderedEntries = _controller.visibleEntries;
        _scheduleViewport();
        return Scaffold(
          appBar: AppBar(
            title: const Text('图库'),
            actions: [
              if (widget.onOpenQueue != null)
                IconButton(
                  tooltip: '导入队列',
                  onPressed: widget.onOpenQueue,
                  icon: const Icon(Icons.download_outlined),
                ),
              GalleryOverflowMenu(
                controller: _controller,
                allowReload: true,
                isDemo: widget.cameraName == null,
                onClearCache: _clearThumbnailCache,
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    SliverToBoxAdapter(
                      child: _PreviewNotice(
                        cameraName: widget.cameraName,
                        connected: _connected,
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                        child: Wrap(
                          spacing: 16,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '文件',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text(
                              '${_renderedEntries.length} 项 · ${_controller.hasMore ? '已载入 ' : ''}${_controller.visibleFiles.length} 个文件',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            Text(
                              '${GalleryFormatFilter(format: _controller.activeFormat, count: 0).label} · ${_controller.mergeRawJpeg ? '合并显示' : '独立显示'}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_controller.persistenceError != null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: TextButton(
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: _controller.preferences.retry,
                            child: const Text('本机设置读取或保存失败，点击重试'),
                          ),
                        ),
                      ),
                    if (_controller.isLoading)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_controller.loadError != null)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _GalleryMessage(
                          icon: Icons.error_outline,
                          title: widget.cameraName == null
                              ? '示例文件载入失败'
                              : '相机文件载入失败',
                          detail: widget.cameraName == null
                              ? '请重新载入图库。'
                              : '请检查相机连接后，从更多菜单重新载入。${_controller.loadError ?? ''}',
                        ),
                      )
                    else if (_controller.visibleFiles.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: _GalleryMessage(
                          icon: Icons.photo_library_outlined,
                          title: '没有此格式的文件',
                          detail: '选择其他格式以查看文件。',
                        ),
                      )
                    else
                      _buildFileGrid(constraints.maxWidth),
                    if (_controller.hasMore)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              if (_controller.loadMoreError != null)
                                Text('后续文件载入失败：${_controller.loadMoreError}'),
                              OutlinedButton(
                                onPressed: _controller.isLoadingMore
                                    ? null
                                    : _controller.loadMoreFiles,
                                child: Text(
                                  _controller.isLoadingMore
                                      ? '正在载入文件信息…'
                                      : '载入更多文件',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 20)),
                  ],
                );
              },
            ),
          ),
          bottomNavigationBar: _SelectionBar(
            selectedCount: _controller.selectedCount,
            isDemo: widget.onImport == null,
            onClear: _controller.clearSelection,
            onImport: _importSelected,
          ),
        );
      },
    );
  }

  Widget _buildFileGrid(double width) {
    const gridGap = 8.0;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final columns = (width / (scale > 1.4 ? 320 : 220))
        .floor()
        .clamp(width < 360 || scale > 1.4 ? 1 : 2, 6)
        .toInt();
    final tileWidth = (width - 40 - (columns - 1) * gridGap) / columns;
    final tileHeight = tileWidth * .75 + 142 * scale;
    final entries = _renderedEntries;

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      sliver: SliverGrid(
        key: _gridKey,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: tileHeight,
          crossAxisSpacing: gridGap,
          mainAxisSpacing: gridGap,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final entry = entries[index];
          return CameraFileTile(
            entry: entry,
            selection: _controller.selectionFor(entry),
            thumbnails: _thumbnails,
            onTap: () => _openPreview(entry),
            onToggleSelection: () => _controller.toggleEntrySelection(entry),
          );
        }, childCount: entries.length),
      ),
    );
  }
}

class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice({this.cameraName, this.connected = false});
  final String? cameraName;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final largeText = MediaQuery.textScalerOf(context).scale(16) >= 20;
          final title = Text(
            cameraName ?? '示例图库',
            style: Theme.of(context).textTheme.titleMedium,
          );
          final state = Text(
            cameraName == null
                ? '未连接 · 不会传输'
                : connected
                ? '已连接 · 按需预览'
                : '连接中断 · 缓存仍可查看',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: AppTheme.mutedText),
          );

          if (constraints.maxWidth < 300 || largeText) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, const SizedBox(height: 4), state],
            );
          }

          return Row(children: [title, const Spacer(), state]);
        },
      ),
    );
  }
}

class _GalleryMessage extends StatelessWidget {
  const _GalleryMessage({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: AppTheme.mutedText),
            const SizedBox(height: 14),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(detail, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.selectedCount,
    required this.isDemo,
    required this.onClear,
    required this.onImport,
  });

  final int selectedCount;
  final bool isDemo;
  final VoidCallback onClear;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final countLabel = Semantics(
      liveRegion: true,
      label: '已选择 $selectedCount 个文件',
      child: Text(
        '已选 $selectedCount 个文件',
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
    final clearButton = TextButton(
      onPressed: onClear,
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      child: const Text('清除'),
    );
    final importButton = Tooltip(
      message: selectedCount == 0
          ? '先选择文件'
          : isDemo
          ? '示例文件仅供预览；不会传输'
          : '将所选原始文件加入导入队列',
      child: FilledButton.icon(
        onPressed: selectedCount == 0 ? null : onImport,
        icon: const Icon(Icons.file_download_outlined, size: 19),
        label: const Text('导入'),
        style: FilledButton.styleFrom(
          minimumSize: const Size(112, 52),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    );

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.canvas,
        border: Border(top: BorderSide(color: AppTheme.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final largeText =
                  MediaQuery.textScalerOf(context).scale(16) >= 20;
              final useStackedLayout = constraints.maxWidth < 440 || largeText;

              if (useStackedLayout) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(alignment: Alignment.centerLeft, child: countLabel),
                    if (selectedCount > 0)
                      Align(
                        alignment: Alignment.centerRight,
                        child: clearButton,
                      ),
                    const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: importButton),
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(child: countLabel),
                  if (selectedCount > 0) ...[
                    clearButton,
                    const SizedBox(width: 8),
                  ],
                  importButton,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
