import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../domain/models/camera_file.dart';
import '../../domain/ports/camera_adapter.dart';
import 'thumbnail_repository.dart';

/// Rendering never starts a request. The viewport or explicit preview owns it.
class CameraThumbnail extends StatelessWidget {
  const CameraThumbnail({
    required this.file,
    required this.repository,
    this.compact = false,
    super.key,
  });

  final CameraFile file;
  final ThumbnailRepository repository;
  final bool compact;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: repository,
    builder: (context, _) {
      final state = repository.stateFor(file);
      final bytes = state.bytes;
      return ColoredBox(
        color: AppTheme.raisedSurface,
        child: bytes != null
            ? Image(
                image: ResizeImage(
                  MemoryImage(bytes),
                  width: CameraAdapter.maxThumbnailEdge,
                  height: CameraAdapter.maxThumbnailEdge,
                  policy: ResizeImagePolicy.fit,
                ),
                fit: BoxFit.contain,
                gaplessPlayback: false,
                semanticLabel: '${file.name} 缩略图',
                errorBuilder: (_, _, _) => _placeholder(retry: true),
              )
            : _placeholder(retry: state.status == ThumbnailStatus.error),
      );
    },
  );

  Widget _placeholder({required bool retry}) => Center(
    child: retry
        ? IconButton(
            tooltip: '重试缩略图',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: () => repository.retry(file),
            icon: const Icon(Icons.refresh, color: AppTheme.mutedText),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ExcludeSemantics(
                child: Icon(
                  Icons.image_outlined,
                  size: 32,
                  color: AppTheme.mutedText,
                ),
              ),
              if (!compact) ...[
                const SizedBox(height: 12),
                const Text('暂无缩略图', textAlign: TextAlign.center),
              ],
            ],
          ),
  );
}
