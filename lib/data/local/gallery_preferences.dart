import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  final Map<String, int> _ratings = {};
  final Set<String> _editedRatings = {};
  bool _merge = false;
  bool _mergeEdited = false;
  bool _loaded = false;
  bool _disposed = false;
  Object? _error;

  bool get mergeRawJpeg => _merge;
  Object? get error => _error;
  int rating(String identity) => _ratings[identity] ?? 0;

  Future<void> _load() async {
    try {
      final raw = await _store.read();
      final data = _decode(raw);
      if (!_mergeEdited) _merge = data.$1;
      for (final item in data.$2.entries) {
        if (!_editedRatings.contains(item.key)) _ratings[item.key] = item.value;
      }
      _loaded = true;
      _error = null;
    } catch (error) {
      _error = error;
    }
    _notify();
  }

  static (bool, Map<String, int>) _decode(String? raw) {
    try {
      final data = jsonDecode(raw ?? 'null');
      if (data is! Map || data['version'] != 1) return (false, {});
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
      );
    } on FormatException {
      return (false, {});
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

  void _save() {
    _writes = _writes.then((_) async {
      await ready;
      // Do not overwrite unread preferences after a transient read failure.
      if (!_loaded) return;
      try {
        await _store.write(
          jsonEncode({
            'version': 1,
            'mergeRawJpeg': _merge,
            'ratings': _ratings,
          }),
        );
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
