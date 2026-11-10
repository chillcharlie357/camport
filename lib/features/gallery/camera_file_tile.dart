import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../domain/models/gallery_entry.dart';
import 'camera_thumbnail.dart';
import 'thumbnail_repository.dart';

class CameraFileTile extends StatelessWidget {
  const CameraFileTile({
    required this.entry,
    required this.selection,
    required this.rating,
    required this.onTap,
    required this.onToggleSelection,
    required this.thumbnails,
    super.key,
  });

  final GalleryEntry entry;
  final bool? selection;
  final int rating;
  final VoidCallback onTap;
  final VoidCallback onToggleSelection;
  final ThumbnailRepository thumbnails;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = entry.representative;
    final selectionLabel = switch (selection) {
      true => '取消选择',
      false => '选择',
      null => '部分已选，选择全部',
    };

    return Material(
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selection != false ? AppTheme.accent : AppTheme.line,
          width: selection != false ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        label:
            '预览 ${file.name}，${entry.formatLabel}${entry.isPhotoEntry ? '，评分 $rating 星' : ''}',
        child: InkWell(
          key: ValueKey('preview-${entry.members.first.id}'),
          onTap: onTap,
          onLongPress: onToggleSelection,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CameraThumbnail(
                      file: file,
                      repository: thumbnails,
                      compact: true,
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Semantics(
                        label:
                            '$selectionLabel ${file.name}，${entry.members.length} 个文件',
                        child: Tooltip(
                          message: selectionLabel,
                          child: SizedBox(
                            key: ValueKey('select-${entry.members.first.id}'),
                            width: 48,
                            height: 48,
                            child: Checkbox(
                              value: selection,
                              tristate: true,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.padded,
                              onChanged: (_) => onToggleSelection(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppTheme.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      entry.formatLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${(entry.byteLength / (1024 * 1024)).toStringAsFixed(1)} MB · ${entry.members.length} 个文件',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    if (entry.isPhotoEntry) ...[
                      const SizedBox(height: 4),
                      Text(
                        rating == 0 ? '未评分' : '★ $rating',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppTheme.accent,
                        ),
                      ),
                    ],
                    if (selection == null)
                      Text(
                        '部分已选',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppTheme.accent,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
