import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import '../../domain/models/camera_profile.dart';

bool isCameraLanAddress(String host, {bool allowLoopback = false}) {
  final ip = InternetAddress.tryParse(host);
  if (ip == null || ip.type != InternetAddressType.IPv4) return false;
  final b = ip.rawAddress;
  return (allowLoopback && b[0] == 127) ||
      b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168) ||
      (b[0] == 169 && b[1] == 254);
}

XmlDocument _document(String source) {
  if (source.length > 1024 * 1024 ||
      RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(source)) {
    throw const FormatException('Unsafe or oversized camera XML');
  }
  return XmlDocument.parse(source);
}

String? _text(XmlNode node, String name) {
  for (final element in node.descendants.whereType<XmlElement>()) {
    if (element.name.local == name) return element.innerText.trim();
  }
  return null;
}

final class SonyCameraEndpoint {
  const SonyCameraEndpoint({
    required this.host,
    required this.id,
    this.ptpPort = 15740,
    this.model,
    this.name,
    this.descriptionUri,
    this.capabilityUri,
    this.mediaServer,
    this.ptpVersion,
    this.pairingRequired = false,
  });

  factory SonyCameraEndpoint.manual(String host, {int port = 15740}) {
    if (!isCameraLanAddress(host) || port < 1 || port > 65535) {
      throw ArgumentError('请输入相机的局域网 IPv4 地址和有效端口');
    }
    return SonyCameraEndpoint(
      host: host,
      id: 'manual:$host:$port',
      ptpPort: port,
    );
  }

  final String host;
  final String id;
  final String? model;
  final String? name;
  final int ptpPort;
  final Uri? descriptionUri;
  final Uri? capabilityUri;
  final bool? mediaServer;
  final String? ptpVersion;
  final bool pairingRequired;

  SonyCameraEndpoint withCapabilities(String source) {
    final xml = _document(source);
    final media = _text(xml, 'X_PTP_MediaServerSupport');
    return SonyCameraEndpoint(
      host: host,
      id: id,
      ptpPort: ptpPort,
      model: model,
      name: name,
      descriptionUri: descriptionUri,
      capabilityUri: capabilityUri,
      mediaServer: media == 'Enable'
          ? true
          : media == 'Disable'
          ? false
          : null,
      ptpVersion: _text(xml, 'X_PTP_Versions') ?? _text(xml, 'X_ServerVersion'),
      pairingRequired: _text(xml, 'X_PTP_PairingNecessity') == 'Necessary',
    );
  }

  CameraProfile toProfile() => CameraProfile(
    id: id,
    displayName: name ?? model ?? 'Sony 相机',
    model: model,
    connectionKind: ConnectionKind.cameraAccessPoint,
    connectionConfiguration: {
      'adapter': 'sony-ptp',
      'host': host,
      'port': '$ptpPort',
      if (mediaServer != null) 'mediaServer': '$mediaServer',
      'ptpVersion': ?ptpVersion,
      if (descriptionUri != null) 'descriptionUri': '$descriptionUri',
    },
  );
}

/// User-initiated SSDP discovery only; never scans arbitrary TCP addresses or
/// fetches media. Announced documents must stay on the responding LAN camera.
class SonyCameraDiscovery {
  SonyCameraDiscovery({
    this.timeout = const Duration(seconds: 5),
    this.allowLoopbackForTesting = false,
  });

  final Duration timeout;
  final bool allowLoopbackForTesting;

  static SonyCameraEndpoint parseDescription(
    String source,
    Uri location, {
    bool allowLoopback = false,
  }) {
    if (location.scheme != 'http' ||
        location.userInfo.isNotEmpty ||
        location.fragment.isNotEmpty ||
        !isCameraLanAddress(location.host, allowLoopback: allowLoopback)) {
      throw const FormatException(
        'Camera description must be on a local camera',
      );
    }
    final xml = _document(source);
    final services = xml.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'service',
    );
    Uri? capability;
    var digitalImaging = false;
    for (final service in services) {
      if (_text(service, 'serviceType') !=
          'urn:schemas-sony-com:service:DigitalImaging:1') {
        continue;
      }
      digitalImaging = true;
      final path = _text(service, 'SCPDURL');
      if (path != null && path.isNotEmpty) {
        final resolved = location.resolve(path);
        if (resolved.scheme != location.scheme ||
            resolved.host != location.host ||
            resolved.port != location.port ||
            resolved.userInfo.isNotEmpty ||
            resolved.fragment.isNotEmpty) {
          throw const FormatException(
            'Capability URL points outside the camera',
          );
        }
        capability = resolved;
      }
    }
    if (!digitalImaging &&
        !(_text(xml, 'manufacturer') ?? '').toLowerCase().contains('sony')) {
      throw const FormatException(
        'Device does not advertise Sony imaging support',
      );
    }
    return SonyCameraEndpoint(
      host: location.host,
      id: _text(xml, 'UDN') ?? 'manual:${location.host}:15740',
      model: _text(xml, 'modelName'),
      name: _text(xml, 'friendlyName'),
      descriptionUri: location,
      capabilityUri: capability,
    );
  }

  Future<String> _fetch(Uri uri) async {
    if (uri.scheme != 'http' ||
        uri.userInfo.isNotEmpty ||
        !isCameraLanAddress(uri.host, allowLoopback: allowLoopbackForTesting)) {
      throw const FormatException(
        'Only local camera HTTP documents are allowed',
      );
    }
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException(
            'Camera description returned ${response.statusCode}',
            uri: uri,
          );
        }
        if (response.contentLength > 1024 * 1024) {
          throw const FormatException('Camera XML too large');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 1024 * 1024) {
            throw const FormatException('Camera XML too large');
          }
          bytes.addAll(chunk);
        }
        return utf8.decode(bytes);
      })().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  Future<SonyCameraEndpoint> readDescription(Uri location) async {
    var endpoint = parseDescription(
      await _fetch(location),
      location,
      allowLoopback: allowLoopbackForTesting,
    );
    final uri = endpoint.capabilityUri;
    if (uri != null) endpoint = endpoint.withCapabilities(await _fetch(uri));
    return endpoint;
  }

  Future<List<SonyCameraEndpoint>> discover() async {
    final addresses = <InternetAddress>[];
    try {
      for (final interface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        addresses.addAll(
          interface.addresses.where((a) => isCameraLanAddress(a.address)),
        );
      }
    } on SocketException {
      // The OS route can still be used when interface enumeration is restricted.
    }
    if (addresses.isEmpty) addresses.add(InternetAddress.anyIPv4);
    final sockets = <RawDatagramSocket>[];
    final subscriptions = <StreamSubscription<RawSocketEvent>>[];
    final locations = <Uri>{};
    try {
      for (final address in addresses.take(8)) {
        try {
          final socket = await RawDatagramSocket.bind(address, 0);
          sockets.add(socket);
          subscriptions.add(
            socket.listen((event) {
              if (event != RawSocketEvent.read) return;
              Datagram? datagram;
              while ((datagram = socket.receive()) != null) {
                final packet = datagram!;
                if (packet.data.length > 16384 || locations.length >= 16) {
                  continue;
                }
                if (!isCameraLanAddress(packet.address.address)) continue;
                final text = latin1.decode(packet.data);
                if (!text.startsWith('HTTP/1.1 200')) continue;
                final match = RegExp(
                  r'^location:\s*(.+)$',
                  multiLine: true,
                  caseSensitive: false,
                ).firstMatch(text);
                final location = Uri.tryParse(match?.group(1)?.trim() ?? '');
                if (location != null &&
                    location.scheme == 'http' &&
                    location.host == packet.address.address &&
                    location.userInfo.isEmpty &&
                    location.fragment.isEmpty) {
                  locations.add(location);
                }
              }
            }, onError: (Object _) {}),
          );
          for (final target in [
            'urn:schemas-sony-com:service:DigitalImaging:1',
            'ssdp:all',
          ]) {
            socket.send(
              latin1.encode(
                'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
                'MAN: "ssdp:discover"\r\nMX: 1\r\nST: $target\r\n\r\n',
              ),
              InternetAddress('239.255.255.250'),
              1900,
            );
          }
        } on SocketException {
          // Another interface or manual camera address may still work.
        }
      }
      if (sockets.isEmpty) {
        throw const SocketException('无法使用本地网络；请检查相机 Wi-Fi 和网络权限');
      }
      await Future<void>.delayed(timeout);
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      for (final socket in sockets) {
        socket.close();
      }
    }
    final endpoints = <String, SonyCameraEndpoint>{};
    // Bounded sequential document fetches prevent SSDP responses from starting
    // unlimited connections. Only documents are read, never originals.
    for (final location in locations.take(8)) {
      try {
        final endpoint = await readDescription(location);
        endpoints[endpoint.id] = endpoint;
      } on IOException {
        continue;
      } on FormatException {
        continue;
      } on TimeoutException {
        continue;
      }
    }
    return endpoints.values.toList(growable: false);
  }
}
