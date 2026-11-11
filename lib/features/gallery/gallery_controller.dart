import 'package:flutter/foundation.dart';

import '../../domain/models/camera_file.dart';
import '../../domain/models/gallery_entry.dart';
import '../../data/local/gallery_preferences.dart';
import '../../domain/ports/camera_adapter.dart';

final class GalleryFormatFilter {
  const GalleryFormatFilter({required this.format, required this.count});

  final CameraFileFormat? format;
  final int count;

  String get label => switch (format) {
    null => '全部',
    CameraFileFormat.raw => 'RAW',
    CameraFileFormat.jpeg => 'JPEG',
    CameraFileFormat.png => 'PNG',
    CameraFileFormat.mp4 => 'MP4',
    CameraFileFormat.avchd => 'AVCHD',
    CameraFileFormat.other => '其他',
  };
}

final class GalleryController extends ChangeNotifier {
  GalleryController({required this._adapter, GalleryPreferences? preferences})
    : preferences = preferences ?? GalleryPreferences.shared {
    this.preferences.addListener(_preferencesChanged);
    loadFiles();
  }

  final GalleryPreferences preferences;
  Map<String, String> _identities = const {};

  void _preferencesChanged() {
    if (!_isDisposed) notifyListeners();
  }

  bool get mergeRawJpeg => preferences.mergeRawJpeg;
  void setMergeRawJpeg(bool value) => preferences.setMergeRawJpeg(value);
  Object? get persistenceError => preferences.error;

  List<GalleryEntry> get visibleEntries => galleryEntries(
    files: visibleFiles,
    identities: _identities,
    merge: mergeRawJpeg,
  );

  int ratingFor(GalleryEntry entry) =>
      entry.isPhotoEntry ? preferences.rating(entry.identity) : 0;

  void setRating(GalleryEntry entry, int rating) {
    if (entry.isPhotoEntry) preferences.setRating(entry.identity, rating);
  }

  /// true = all, false = none, null = a partially selected merged entry.
  bool? selectionFor(GalleryEntry entry) {
    final count = entry.members.where(isSelected).length;
    return count == 0
        ? false
        : count == entry.members.length
        ? true
        : null;
  }

  void toggleEntrySelection(GalleryEntry entry) {
    if (selectionFor(entry) == true) {
      _selectedIds.removeAll(entry.members.map((file) => file.id));
      for (final file in entry.members) {
        _selectedSnapshots.remove(file.id);
      }
    } else {
      _selectedIds.addAll(entry.members.map((file) => file.id));
      for (final file in entry.members) {
        _selectedSnapshots[file.id] = file;
      }
    }
    notifyListeners();
  }

  /// Members with the same photo filename key, even when the gallery is split or
  /// format-filtered. Inspecting these does not add hidden files to selection.
  List<CameraFile> membersFor(GalleryEntry entry) => List.unmodifiable(
    _files.where((file) => _identities[file.id] == entry.identity),
  );

  Set<String> get selectedFileIds => Set.unmodifiable(_selectedIds);
  List<CameraFile> get selectedFiles {
    final loaded = _files.map((f) => f.id).toSet();
    return List.unmodifiable([
      ..._files.where(isSelected),
      ..._selectedSnapshots.values.where(
        (f) => _selectedIds.contains(f.id) && !loaded.contains(f.id),
      ),
    ]);
  }

  final CameraAdapter _adapter;
  List<CameraFile> _files = const [];
  final Set<String> _selectedIds = {};
  final _selectedSnapshots = <String, CameraFile>{};
  String? _nextCursor;
  bool _isLoadingMore = false;
  Object? _loadMoreError;
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
      CameraFileFormat.png,
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
  bool get hasMore => _nextCursor != null;
  bool get isLoadingMore => _isLoadingMore;
  Object? get loadMoreError => _loadMoreError;
  Object? get loadError => _loadError;
  int get selectedCount => _selectedIds.length;
  bool isSelected(CameraFile file) => _selectedIds.contains(file.id);

  Future<void> loadFiles() async {
    if (_isDisposed) return;

    final requestGeneration = ++_requestGeneration;
    _isLoading = true;
    _loadError = null;
    _nextCursor = null;
    _isLoadingMore = false;
    _loadMoreError = null;
    notifyListeners();
    try {
      final page = await _adapter.listFiles();
      if (!_isCurrentRequest(requestGeneration)) return;
      _files = List.unmodifiable(page.items);
      _nextCursor = page.nextCursor;
      _identities = photoIdentities(_files);
      _reconcileSelection();
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

  void _reconcileSelection() {
    for (final file in _files) {
      final old = _selectedSnapshots[file.id];
      if (old != null &&
          old.thumbnailKey != null &&
          file.thumbnailKey != old.thumbnailKey) {
        _selectedIds.remove(file.id);
        _selectedSnapshots.remove(file.id);
      } else if (_selectedIds.contains(file.id)) {
        _selectedSnapshots[file.id] = file;
      }
    }
    if (!hasMore) {
      _selectedIds.retainAll(_files.map((f) => f.id));
      _selectedSnapshots.removeWhere((id, _) => !_selectedIds.contains(id));
    }
  }

  Future<void> loadMoreFiles() async {
    final cursor = _nextCursor;
    if (_isDisposed || _isLoading || _isLoadingMore || cursor == null) return;
    final generation = _requestGeneration;
    _isLoadingMore = true;
    _loadMoreError = null;
    notifyListeners();
    try {
      final page = await _adapter.listFiles(cursor: cursor);
      if (!_isCurrentRequest(generation)) return;
      if (page.nextCursor == cursor) throw StateError('相机分页没有前进，请重新载入图库');
      final files = {
        for (final f in _files) f.id: f,
        for (final f in page.items) f.id: f,
      };
      _files = List.unmodifiable(files.values);
      _nextCursor = page.nextCursor;
      _identities = photoIdentities(_files);
      _reconcileSelection();
    } catch (error) {
      if (_isCurrentRequest(generation)) _loadMoreError = error;
    } finally {
      if (_isCurrentRequest(generation)) {
        _isLoadingMore = false;
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
    if (!_selectedIds.add(file.id)) {
      _selectedIds.remove(file.id);
      _selectedSnapshots.remove(file.id);
    } else {
      _selectedSnapshots[file.id] = file;
    }
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedIds.isEmpty) return;
    _selectedIds.clear();
    _selectedSnapshots.clear();
    notifyListeners();
  }

  bool _isCurrentRequest(int generation) =>
      !_isDisposed && generation == _requestGeneration;

  @override
  void dispose() {
    preferences.removeListener(_preferencesChanged);
    _isDisposed = true;
    _requestGeneration++;
    super.dispose();
  }
}
