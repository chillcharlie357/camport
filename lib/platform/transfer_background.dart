import 'dart:async';

import 'package:flutter/services.dart';

enum BackgroundTransferEvent {
  pauseRequested,
  resumeRequested,
  budgetExpired,
  networkLost,
}

/// Protects the existing Dart transfer runner; never starts or queues downloads.
///
/// Use one bridge per channel. The application runner must listen to [events],
/// persist/pause work on interruption, and call [stop] in its finally block.
class TransferBackground {
  TransferBackground({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('sony_camera/transfer_background') {
    _channel.setMethodCallHandler(_handleCall);
  }

  static final instance = TransferBackground();

  final MethodChannel _channel;
  final _events = StreamController<BackgroundTransferEvent>.broadcast();
  bool _disposed = false;

  Stream<BackgroundTransferEvent> get events => _events.stream;

  /// Android's notification visibility after start. Other platforms may omit it.
  bool? get notificationsEnabled => _notificationsEnabled;
  bool? _notificationsEnabled;
  String? get notificationStatus => _notificationStatus;
  String? _notificationStatus;
  String? get statusMessage => _statusMessage;
  String? _statusMessage;

  Future<void> start({required int pendingFiles}) async {
    if (pendingFiles <= 0) {
      throw ArgumentError.value(
        pendingFiles,
        'pendingFiles',
        'Must be positive',
      );
    }
    _notificationsEnabled = null;
    _notificationStatus = null;
    _statusMessage = null;
    final result = await _invoke<Object?>('start', {
      'pendingFiles': pendingFiles,
    });
    if (result is Map) {
      _notificationsEnabled = result['notificationsEnabled'] as bool?;
      _notificationStatus = result['notificationStatus'] as String?;
      _statusMessage = result['message'] as String?;
    }
  }

  Future<void> update({
    required String filename,
    required int bytes,
    int? total,
  }) async {
    if (filename.trim().isEmpty || bytes < 0 || (total != null && total < 0)) {
      throw ArgumentError(
        'A filename and nonnegative byte counts are required',
      );
    }
    await _invoke<void>('update', {
      'filename': filename,
      'bytes': bytes,
      'total': total,
    });
  }

  Future<void> stop() => _invoke<void>('stop');

  /// Pins future process sockets/DNS to the current Wi-Fi, including camera APs
  /// without internet. Call before opening the PTP/IP session and check connected.
  /// An optional host is the IPv4 gateway, not proof of a compatible camera.
  Future<Map<String, Object?>> prepareNetwork() async {
    final result = await _invoke<Object?>('prepareNetwork');
    if (result is! Map ||
        result['connected'] is! bool ||
        result['message'] is! String ||
        (result['host'] != null && result['host'] is! String)) {
      throw const FormatException(
        'Invalid background transfer network response',
      );
    }
    return Map<String, Object?>.from(result);
  }

  /// Disconnect only after the runner has stopped; Android rejects active work.
  Future<void> releaseNetwork() => _invoke<void>('releaseNetwork');

  Future<void> openWifiSettings() => _invoke<void>('openWifiSettings');

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (_disposed) throw StateError('TransferBackground has been disposed');
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      throw UnsupportedError(
        'Background transfer protection is not available on this platform '
        '(sony_camera/transfer_background.$method).',
      );
    }
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method != 'event') {
      throw MissingPluginException(
        'Unknown background transfer callback: ${call.method}',
      );
    }
    for (final event in BackgroundTransferEvent.values) {
      if (call.arguments == event.name) {
        if (!_disposed) _events.add(event);
        return;
      }
    }
  }

  /// Detaches the bridge, not the native transfer. Stop the runner first.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    await _events.close();
  }
}
