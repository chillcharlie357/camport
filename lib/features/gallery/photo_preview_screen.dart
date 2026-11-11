import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../domain/models/gallery_entry.dart';
import '../../domain/models/camera_file.dart';
import 'gallery_controller.dart';
import 'format_filter_row.dart';
import 'camera_thumbnail.dart';
import 'thumbnail_repository.dart';

class PhotoPreviewScreen extends StatefulWidget {
  const PhotoPreviewScreen({
    required this.entry,
    required this.controller,
    required this.thumbnails,
    this.isDemo = true,
    this.onImport,
    super.key,
  });
  final GalleryEntry entry;
  final GalleryController controller;
  final ThumbnailRepository thumbnails;
  final bool isDemo;
  final Future<void> Function(List<CameraFile>)? onImport;

  @override
  State<PhotoPreviewScreen> createState() => _PhotoPreviewScreenState();
}

class _PhotoPreviewScreenState extends State<PhotoPreviewScreen> {
  late String _memberId = widget.entry.representative.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.thumbnails.loadForPreview(widget.entry.representative);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final members = widget.controller.membersFor(widget.entry);
        final file = members.firstWhere(
          (f) => f.id == _memberId,
          orElse: () => widget.entry.representative,
        );
        final rating = widget.controller.ratingFor(widget.entry);
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.entry.isPhotoEntry ? '照片预览' : '文件预览'),
            actions: [
              GalleryOverflowMenu(
                controller: widget.controller,
                isDemo: widget.isDemo,
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                        aspectRatio: 3 / 2,
                        child: CameraThumbnail(
                          file: file,
                          repository: widget.thumbnails,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text('缩略图预览'),
                      const SizedBox(height: 20),
                      Text(
                        file.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${cameraFormatLabel(file.format)} · ${(file.byteLength / (1024 * 1024)).toStringAsFixed(1)} MB',
                      ),
                      const SizedBox(height: 24),
                      Text(
                        '原始文件 · ${members.length} 个',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final member in members)
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(48, 48),
                                backgroundColor: member.id == file.id
                                    ? AppTheme.raisedSurface
                                    : null,
                                side: BorderSide(
                                  color: member.id == file.id
                                      ? AppTheme.accent
                                      : AppTheme.line,
                                ),
                              ),
                              onPressed: () {
                                setState(() => _memberId = member.id);
                                widget.thumbnails.loadForPreview(member);
                              },
                              child: Text(
                                member.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                      if (widget.entry.isPhotoEntry) ...[
                        const SizedBox(height: 24),
                        const Divider(),
                        Text(
                          '照片评分',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Semantics(
                          liveRegion: true,
                          child: Text('$rating / 5 星'),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            for (var star = 1; star <= 5; star++)
                              IconButton(
                                tooltip: '评分 $star 星',
                                isSelected: rating >= star,
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                icon: const Icon(Icons.star_outline),
                                selectedIcon: const Icon(
                                  Icons.star,
                                  color: AppTheme.accent,
                                ),
                                onPressed: () => widget.controller.setRating(
                                  widget.entry,
                                  star,
                                ),
                              ),
                            TextButton(
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed: () =>
                                  widget.controller.setRating(widget.entry, 0),
                              child: const Text('清除评分'),
                            ),
                          ],
                        ),
                        const Text('同名 RAW/JPG/PNG 共用评分。'),
                        const SizedBox(height: 8),
                        const Text('评分已暂存；本机原文件和相机原文件尚未写入。'),
                      ],
                      if (widget.controller.persistenceError != null)
                        TextButton(
                          onPressed: widget.controller.preferences.retry,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          child: const Text('本机设置保存失败，点击重试'),
                        ),
                      if (widget.onImport != null) ...[
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: () => widget.onImport!([file]),
                          icon: const Icon(Icons.file_download_outlined),
                          label: Text(
                            '导入此 ${cameraFormatLabel(file.format)} 文件',
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Text(
                        widget.isDemo
                            ? '示例文件仅供查看；未连接相机，不会传输文件。'
                            : '当前为缩略图预览；只有选择导入时才传输原片。',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
