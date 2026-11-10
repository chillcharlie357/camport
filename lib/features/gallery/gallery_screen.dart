import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../domain/ports/camera_adapter.dart';
import 'camera_file_tile.dart';
import 'format_filter_row.dart';
import 'gallery_controller.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({required this.adapter, super.key});

  final CameraAdapter adapter;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late final GalleryController _controller;

  @override
  void initState() {
    super.initState();
    _controller = GalleryController(adapter: widget.adapter);
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
              IconButton(
                tooltip: '重新载入示例文件',
                onPressed: _controller.loadFiles,
                icon: const Icon(Icons.refresh_rounded),
              ),
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
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '文件',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            Text(
                              '${_controller.visibleFiles.length} 个',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: FormatFilterRow(
                        filters: _controller.filters,
                        activeFormat: _controller.activeFormat,
                        onSelected: _controller.selectFormat,
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
    final columns = width < 720 ? 2 : (width / 260).floor().clamp(3, 6).toInt();
    final tileWidth = (width - 40 - (columns - 1) * 12) / columns;
    final tileHeight = (tileWidth * 1.38).clamp(248.0, 370.0).toDouble();

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: tileHeight,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final file = _controller.visibleFiles[index];
          return CameraFileTile(
            file: file,
            selected: _controller.isSelected(file),
            onTap: () => _controller.toggleSelection(file),
          );
        }, childCount: _controller.visibleFiles.length),
      ),
    );
  }
}

class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border.all(color: AppTheme.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18, color: AppTheme.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '本地预览 · 示例文件',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          Text(
            '未连接相机',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: AppTheme.mutedText),
          ),
        ],
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
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.canvas,
        border: Border(top: BorderSide(color: AppTheme.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  label: '已选择 $selectedCount 项',
                  child: Text(
                    '已选 $selectedCount 项',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              if (selectedCount > 0) ...[
                TextButton(
                  onPressed: onClear,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: const Text('清除'),
                ),
                const SizedBox(width: 8),
              ],
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: onImport,
                  icon: const Icon(Icons.file_download_outlined, size: 19),
                  label: const Text('导入'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(112, 52),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
