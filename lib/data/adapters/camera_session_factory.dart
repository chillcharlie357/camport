import 'dart:typed_data';

import '../../domain/models/camera_profile.dart';
import '../../domain/ports/camera_session.dart';
import '../sony/sony_ptp_adapter.dart';
import '../sony/sony_discovery.dart';

/// Stable adapter ID lives in the profile configuration for reconnect and
/// transfer recovery. Older Sony profiles without an ID stay compatible.
abstract interface class CameraSessionFactory {
  String get id;

  /// Validate a restored profile before the runtime accepts it.
  void validateSavedProfile(CameraProfile profile);
  Future<List<CameraProfile>> discover();
  CameraSession create({required Uint8List guid});
}

final class SonyPtpSessionFactory implements CameraSessionFactory {
  const SonyPtpSessionFactory();

  @override
  String get id => 'sony-ptp';

  @override
  void validateSavedProfile(CameraProfile profile) {
    final host = profile.connectionConfiguration['host'] ?? '';
    final port = int.tryParse(
      profile.connectionConfiguration['port'] ?? '15740',
    );
    if (port == null) throw const FormatException('Invalid Sony camera port');
    SonyCameraEndpoint.manual(host, port: port);
  }

  @override
  Future<List<CameraProfile>> discover() async =>
      (await SonyCameraDiscovery().discover())
          .map((endpoint) => endpoint.toProfile())
          .toList();

  @override
  CameraSession create({required Uint8List guid}) =>
      SonyPtpCameraAdapter(guid: guid);
}

final class CameraSessionRegistry {
  CameraSessionRegistry(List<CameraSessionFactory> factories)
    : _factories = Map.unmodifiable({
        for (final factory in factories) factory.id: factory,
      }) {
    if (_factories.isEmpty ||
        _factories.keys.any((id) => id.isEmpty) ||
        _factories.length != factories.length) {
      throw ArgumentError('Camera adapter IDs must be unique and nonempty');
    }
  }

  final Map<String, CameraSessionFactory> _factories;

  String adapterId(CameraProfile profile) =>
      profile.connectionConfiguration['adapter'] ?? 'sony-ptp';

  void validateSavedProfile(CameraProfile profile) {
    final id = adapterId(profile);
    final factory = _factories[id];
    if (factory == null) throw UnsupportedError('没有可用于此相机的连接适配器：$id');
    factory.validateSavedProfile(profile);
  }

  Future<List<CameraProfile>> discover() async {
    final found = <CameraProfile>[];
    for (final factory in _factories.values) {
      found.addAll(await factory.discover());
    }
    return found;
  }

  CameraSession create(CameraProfile profile, Uint8List guid) {
    validateSavedProfile(profile);
    final id = adapterId(profile);
    final factory = _factories[id];
    if (factory == null) {
      throw UnsupportedError('没有可用于此相机的连接适配器：$id');
    }
    return factory.create(guid: Uint8List.fromList(guid));
  }
}
