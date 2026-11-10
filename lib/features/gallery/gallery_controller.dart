import 'package:flutter/foundation.dart';

import '../../domain/models/camera_file.dart';
import '../../domain/ports/camera_adapter.dart';

final class GalleryFormatFilter {
  const GalleryFormatFilter({required this.format, required this.count});

  final CameraFileFormat? format;
  final int count;

  String get label => switch (format) {
    null => '全部',
    CameraFileFormat.raw => 'RAW',
    CameraFileFormat.jpeg => 'JPEG',
    CameraFileFormat.mp4 => 'MP4',
    CameraFileFormat.avchd => 'AVCHD',
    CameraFileFormat.other => '其他',
  };
}

final class GalleryController extends ChangeNotifier {
  GalleryController({required CameraAdapter adapter}) : _adapter = adapter {
    loadFiles();
  }

  final CameraAdapter _adapter;
  List<CameraFile> _files = const [];
  final Set<String> _selectedIds = {};
  CameraFileFormat? _activeFormat;
  bool _isLoading = true;
  Object? _loadError;
  int _requestGeneration = 0;
  bool _isDisposed = false;

  List<CameraFile> get visibleFiles => List<CameraFile>.unmodifiable(
    _files.where((file) {
      return _activeFormat == null || file.format == _activeFormat;
    }),
  );

  List<GalleryFormatFilter> get filters {
    final counts = <CameraFileFormat, int>{};
    for (final file in _files) {
      counts.update(file.format, (count) => count + 1, ifAbsent: () => 1);
    }

    const order = [
      CameraFileFormat.raw,
      CameraFileFormat.jpeg,
      CameraFileFormat.mp4,
      CameraFileFormat.avchd,
      CameraFileFormat.other,
    ];
    return [
      GalleryFormatFilter(format: null, count: _files.length),
      for (final format in order)
        if (counts.containsKey(format))
          GalleryFormatFilter(format: format, count: counts[format]!),
    ];
  }

  CameraFileFormat? get activeFormat => _activeFormat;
  bool get isLoading => _isLoading;
  Object? get loadError => _loadError;
  int get selectedCount => _selectedIds.length;
  bool isSelected(CameraFile file) => _selectedIds.contains(file.id);

  Future<void> loadFiles() async {
    if (_isDisposed) return;

    final requestGeneration = ++_requestGeneration;
    _isLoading = true;
    _loadError = null;
    notifyListeners();
    try {
      final page = await _adapter.listFiles();
      if (!_isCurrentRequest(requestGeneration)) return;
      _files = page.items;
    } catch (error) {
      if (!_isCurrentRequest(requestGeneration)) return;
      _loadError = error;
    } finally {
      if (_isCurrentRequest(requestGeneration)) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  void selectFormat(CameraFileFormat? format) {
    if (_activeFormat == format) return;
    _activeFormat = format;
    notifyListeners();
  }

  void toggleSelection(CameraFile file) {
    if (!_selectedIds.add(file.id)) _selectedIds.remove(file.id);
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedIds.isEmpty) return;
    _selectedIds.clear();
    notifyListeners();
  }

  bool _isCurrentRequest(int generation) =>
      !_isDisposed && generation == _requestGeneration;

  @override
  void dispose() {
    _isDisposed = true;
    _requestGeneration++;
    super.dispose();
  }
}
