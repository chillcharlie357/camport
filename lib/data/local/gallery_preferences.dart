import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/camera_file.dart';

abstract interface class GalleryPreferenceStore {
  Future<String?> read();
  Future<void> write(String value);
}

final class SharedGalleryPreferenceStore implements GalleryPreferenceStore {
  SharedGalleryPreferenceStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const storageKey = 'sony.gallery.preferences.v1';
  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> read() async {
    try {
      return await _preferences.getString(storageKey);
    } on TypeError {
      // A value of the wrong platform type is invalid persisted data.
      return null;
    }
  }

  @override
  Future<void> write(String value) => _preferences.setString(storageKey, value);
}

/// A desired rating is not evidence of a write to either original.
/// This record stays pending until a format-specific writer has written and
/// read back the rating from the physical file.
final class RatingWriteIntent {
  const RatingWriteIntent({
    required this.rating,
    required this.localStatus,
    required this.cameraStatus,
  });

  final int rating;
  final String localStatus;
  final String cameraStatus;

  Map<String, Object> toJson() => {
    'rating': rating,
    'local': localStatus,
    'camera': cameraStatus,
  };

  static RatingWriteIntent? decode(Object? raw) {
    if (raw is! Map ||
        raw['rating'] is! int ||
        (raw['rating'] as int) < 0 ||
        (raw['rating'] as int) > 5 ||
        raw['local'] != 'pendingImport' ||
        raw['camera'] != 'pendingCapability') {
      return null;
    }
    return RatingWriteIntent(
      rating: raw['rating'] as int,
      localStatus: 'pendingImport',
      cameraStatus: 'pendingCapability',
    );
  }
}

/// Shared for the app lifetime, including gallery routes that overlap while a
/// platform write is pending. Reads finish before writes, and writes serialize.
final class GalleryPreferences extends ChangeNotifier {
  GalleryPreferences({required this._store}) {
    ready = _load();
  }

  static final shared = GalleryPreferences(
    store: SharedGalleryPreferenceStore(),
  );
  final GalleryPreferenceStore _store;
  late final Future<void> ready;
  Future<void> _writes = Future.value();
  int _revision = 0;
  int _persistedRevision = 0;
  final Map<String, int> _ratings = {};
  final Map<String, RatingWriteIntent> _writeIntents = {};
  final Set<String> _editedRatings = {};
  final Set<String> _editedIntents = {};
  bool _merge = false;
  bool _mergeEdited = false;
  bool _loaded = false;
  bool _disposed = false;
  Object? _error;

  bool get mergeRawJpeg => _merge;
  Object? get error => _error;
  bool get hasPendingSave => !_loaded || _revision != _persistedRevision;
  int rating(String identity) => _ratings[identity] ?? 0;

  RatingWriteIntent? writeIntent(String identity, CameraFile member) {
    final desired = _ratings[identity];
    if (desired == null) return null;
    final stored = _writeIntents[_memberKey(identity, member)];
    return stored?.rating == desired ? stored : _pending(desired);
  }

  static RatingWriteIntent _pending(int value) => RatingWriteIntent(
    rating: value,
    localStatus: 'pendingImport',
    cameraStatus: 'pendingCapability',
  );

  static String _memberKey(String identity, CameraFile member) =>
      jsonEncode([identity, member.id, member.thumbnailKey]);

  Future<void> _load() async {
    try {
      final raw = await _store.read();
      final data = _decode(raw);
      if (!_mergeEdited) _merge = data.$1;
      for (final item in data.$2.entries) {
        if (!_editedRatings.contains(item.key)) _ratings[item.key] = item.value;
      }
      for (final item in data.$3.entries) {
        if (!_editedIntents.contains(item.key)) {
          _writeIntents[item.key] = item.value;
        }
      }
      _loaded = true;
      _error = null;
    } catch (error) {
      _error = error;
    }
    _notify();
  }

  static (bool, Map<String, int>, Map<String, RatingWriteIntent>) _decode(
    String? raw,
  ) {
    try {
      final data = jsonDecode(raw ?? 'null');
      if (data is! Map || data['version'] != 1) return (false, {}, {});
      final merge = data['mergeRawJpeg'];
      final ratings = data['ratings'];
      return (
        merge is bool ? merge : false,
        <String, int>{
          if (ratings is Map)
            for (final item in ratings.entries)
              if (item.key is String &&
                  (item.key as String).isNotEmpty &&
                  item.value is int &&
                  (item.value as int) >= 0 &&
                  (item.value as int) <= 5)
                item.key as String: item.value as int,
        },
        <String, RatingWriteIntent>{
          if (data['writeIntents'] is Map)
            for (final item in (data['writeIntents'] as Map).entries)
              if (item.key is String &&
                  (item.key as String).isNotEmpty &&
                  RatingWriteIntent.decode(item.value) != null)
                item.key as String: RatingWriteIntent.decode(item.value)!,
        },
      );
    } on FormatException {
      return (false, {}, {});
    }
  }

  void setMergeRawJpeg(bool value) {
    // Mark even an unchanged value: a user action wins over an in-flight load.
    _mergeEdited = true;
    _merge = value;
    _notify();
    _save();
  }

  void setRating(String identity, int value) {
    if (value < 0 || value > 5) throw RangeError.range(value, 0, 5, 'rating');
    _editedRatings.add(identity);
    _ratings[identity] = value;
    _notify();
    _save();
  }

  void setRatingForMembers(
    String identity,
    int value,
    Iterable<CameraFile> members,
  ) {
    if (value < 0 || value > 5) throw RangeError.range(value, 0, 5, 'rating');
    _editedRatings.add(identity);
    _ratings[identity] = value;
    for (final member in members) {
      final key = _memberKey(identity, member);
      _editedIntents.add(key);
      _writeIntents[key] = _pending(value);
    }
    _notify();
    _save();
  }

  /// A later camera page can reveal another member of a rated photo group.
  /// Save once per page, while retaining one intent per physical file.
  void registerPhotoGroups(Map<String, List<CameraFile>> groups) {
    var changed = false;
    for (final group in groups.entries) {
      final desired = _ratings[group.key];
      if (desired == null) continue;
      for (final member in group.value) {
        final key = _memberKey(group.key, member);
        if (_writeIntents[key]?.rating == desired) continue;
        _editedIntents.add(key);
        _writeIntents[key] = _pending(desired);
        changed = true;
      }
    }
    if (changed) {
      _notify();
      _save();
    }
  }

  void _save() {
    ++_revision;
    _writes = _writes.then((_) async {
      await ready;
      // Do not overwrite unread preferences after a transient read failure.
      if (!_loaded) return;
      try {
        // Capture both the data and its revision together. A newer tap can
        // happen while the platform write is in progress.
        final snapshotRevision = _revision;
        final snapshot = jsonEncode({
          'version': 1,
          'mergeRawJpeg': _merge,
          'ratings': _ratings,
          'writeIntents': _writeIntents.map(
            (key, value) => MapEntry(key, value.toJson()),
          ),
        });
        await _store.write(snapshot);
        _persistedRevision = snapshotRevision;
        _error = null;
      } catch (error) {
        _error = error;
      }
      _notify();
    });
  }

  Future<void> retry() async {
    await ready;
    await _writes;
    if (!_loaded) await _load();
    _save();
    await flush();
  }

  /// Includes writes queued while a previous write was completing.
  Future<void> flush() async {
    Future<void> current;
    do {
      current = _writes;
      await current;
    } while (!identical(current, _writes));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
