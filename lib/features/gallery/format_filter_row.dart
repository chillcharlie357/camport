import 'package:flutter/material.dart';

import 'gallery_controller.dart';

class GalleryOverflowMenu extends StatelessWidget {
  const GalleryOverflowMenu({
    required this.controller,
    this.allowReload = false,
    super.key,
  });
  final GalleryController controller;
  final bool allowReload;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: const Icon(Icons.more_horiz),
      constraints: const BoxConstraints(minWidth: 180),
      onSelected: (action) {
        if (action == 'reload') {
          controller.loadFiles();
          return;
        }
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .85,
            maxWidth: 560,
          ),
          builder: (_) => GalleryDisplaySheet(controller: controller),
        );
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'display', height: 48, child: Text('筛选与显示')),
        if (allowReload)
          PopupMenuItem(
            value: 'reload',
            height: 48,
            enabled: !controller.isLoading,
            child: const Text('重新载入示例文件'),
          ),
      ],
    );
  }
}

/// Formats are intentionally presented only inside More → 筛选与显示.
class GalleryDisplaySheet extends StatelessWidget {
  const GalleryDisplaySheet({required this.controller, super.key});
  final GalleryController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '筛选与显示',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭筛选',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('文件格式'),
              const SizedBox(height: 8),
              for (final filter in controller.filters)
                ListTile(
                  minTileHeight: 48,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  title: Text(filter.label),
                  subtitle: Text('${filter.count} 个文件'),
                  selected: filter.format == controller.activeFormat,
                  trailing: filter.format == controller.activeFormat
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => controller.selectFormat(filter.format),
                ),
              const Divider(),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: const Text('合并显示同名文件'),
                subtitle: const Text('同名 RAW 与 JPG/JPEG/PNG 合为一项'),
                value: controller.mergeRawJpeg,
                onChanged: controller.setMergeRawJpeg,
              ),
              const SizedBox(height: 12),
              const Text('格式先筛选原文件，再合并显示。切换显示方式会保留已选文件和照片评分。'),
            ],
          ),
        ),
      ),
    );
  }
}
