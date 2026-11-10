import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../domain/models/camera_file.dart';
import 'gallery_controller.dart';

class FormatFilterRow extends StatelessWidget {
  const FormatFilterRow({
    required this.filters,
    required this.activeFormat,
    required this.onSelected,
    super.key,
  });

  final List<GalleryFormatFilter> filters;
  final CameraFileFormat? activeFormat;
  final ValueChanged<CameraFileFormat?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filter = filters[index];
          final selected = filter.format == activeFormat;
          return Semantics(
            label: '${filter.label}，${filter.count} 个文件',
            selected: selected,
            button: true,
            onTap: () => onSelected(filter.format),
            child: ExcludeSemantics(
              child: ChoiceChip(
                label: Text('${filter.label}  ${filter.count}'),
                selected: selected,
                onSelected: (_) => onSelected(filter.format),
                showCheckmark: false,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                labelStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: selected ? AppTheme.text : AppTheme.mutedText,
                ),
                backgroundColor: AppTheme.surface,
                selectedColor: const Color(0xFF42351F),
                side: BorderSide(
                  color: selected ? AppTheme.accent : AppTheme.line,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
