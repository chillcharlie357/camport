import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../data/local/gallery_preferences.dart';
import '../../domain/ports/camera_adapter.dart';
import 'camera_file_tile.dart';
import 'format_filter_row.dart';
import 'gallery_controller.dart';
import 'photo_preview_screen.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({required this.adapter, this.preferences, super.key});

  final CameraAdapter adapter;
  final GalleryPreferences? preferences;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late final GalleryController _controller;

  @override
  void initState() {
    super.initState();
    _controller = GalleryController(
      adapter: widget.adapter,
      preferences: widget.preferences,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
        return Scaffold(
          appBar: AppBar(
            title: const Text('图库'),
            actions: [
              GalleryOverflowMenu(controller: _controller, allowReload: true),
            ],
          ),
          body: SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(child: _PreviewNotice()),
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
                              '${_controller.visibleEntries.length} 项 · ${_controller.visibleFiles.length} 个文件',
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
                          title: '示例文件载入失败',
                          detail: '请重新载入图库。',
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
                    const SliverToBoxAdapter(child: SizedBox(height: 20)),
                  ],
                );
              },
            ),
          ),
          bottomNavigationBar: _SelectionBar(
            selectedCount: _controller.selectedCount,
            onClear: _controller.clearSelection,
            onImport: _showImportNotice,
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
    final entries = _controller.visibleEntries;

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      sliver: SliverGrid(
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
            rating: _controller.ratingFor(entry),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    PhotoPreviewScreen(entry: entry, controller: _controller),
              ),
            ),
            onToggleSelection: () => _controller.toggleEntrySelection(entry),
          );
        }, childCount: entries.length),
      ),
    );
  }
}

class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final largeText = MediaQuery.textScalerOf(context).scale(16) >= 20;
          final title = Text(
            '示例图库',
            style: Theme.of(context).textTheme.titleMedium,
          );
          final state = Text(
            '未连接 · 不会传输',
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
    required this.onClear,
    required this.onImport,
  });

  final int selectedCount;
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
      message: selectedCount == 0 ? '先选择文件' : '示例文件仅供预览；不会传输',
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
