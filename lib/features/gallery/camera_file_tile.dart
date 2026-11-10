import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../domain/models/camera_file.dart';

class CameraFileTile extends StatelessWidget {
  const CameraFileTile({
    required this.file,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final CameraFile file;
  final bool selected;
  final VoidCallback onTap;

  String get _formatLabel => switch (file.format) {
    CameraFileFormat.raw => 'RAW',
    CameraFileFormat.jpeg => 'JPEG',
    CameraFileFormat.mp4 => 'MP4',
    CameraFileFormat.avchd => 'AVCHD',
    CameraFileFormat.other => '其他',
  };

  @override
  Widget build(BuildContext context) {
    final format = file.format;
    final theme = Theme.of(context);

    return Semantics(
      button: true,
      selected: selected,
      label: '${file.name}，$_formatLabel，${_sizeLabel(file.byteLength)}',
      hint: selected ? '双击取消选择' : '双击选择文件',
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          color: AppTheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: selected ? AppTheme.accent : AppTheme.line,
              width: selected ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _ThumbnailPlaceholder(
                    format: format,
                    selected: selected,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              file.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: AppTheme.text,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _FormatBadge(label: _formatLabel),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Text(
                        _sizeLabel(file.byteLength),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppTheme.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _sizeLabel(int bytes) {
    final megabytes = bytes / (1024 * 1024);
    return '${megabytes.toStringAsFixed(1)} MB';
  }
}

class _ThumbnailPlaceholder extends StatelessWidget {
  const _ThumbnailPlaceholder({required this.format, required this.selected});

  final CameraFileFormat format;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final icon = switch (format) {
      CameraFileFormat.raw || CameraFileFormat.jpeg => Icons.landscape_outlined,
      CameraFileFormat.mp4 => Icons.play_circle_outline_rounded,
      CameraFileFormat.avchd => Icons.movie_outlined,
      CameraFileFormat.other => Icons.insert_drive_file_outlined,
    };
    final label = switch (format) {
      CameraFileFormat.raw || CameraFileFormat.jpeg => 'PHOTO',
      CameraFileFormat.mp4 || CameraFileFormat.avchd => 'VIDEO',
      CameraFileFormat.other => 'FILE',
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: AppTheme.raisedSurface),
        Positioned(
          left: 14,
          top: 13,
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: AppTheme.mutedText, letterSpacing: 1.5),
          ),
        ),
        Center(child: Icon(icon, size: 42, color: const Color(0xFF85897D))),
        Positioned(
          right: 11,
          top: 10,
          child: Icon(
            selected ? Icons.check_circle : Icons.circle_outlined,
            size: 23,
            color: selected ? AppTheme.accent : AppTheme.mutedText,
          ),
        ),
      ],
    );
  }
}

class _FormatBadge extends StatelessWidget {
  const _FormatBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: AppTheme.mutedText,
          letterSpacing: 0.4,
          fontSize: 9,
        ),
      ),
    );
  }
}
