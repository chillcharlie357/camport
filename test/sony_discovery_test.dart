import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sony_camera/data/sony/sony_discovery.dart';

void main() {
  test(
    'DD resolves the advertised DigitalImaging service on the same camera',
    () {
      final endpoint = SonyCameraDiscovery.parseDescription('''
      <root xmlns="urn:schemas-upnp-org:device-1-0"><device>
      <manufacturer>Sony Corporation</manufacturer><modelName>ZV-E10</modelName>
      <friendlyName>Camera</friendlyName><UDN>uuid:camera-123</UDN><serviceList>
      <service><serviceType>urn:schemas-sony-com:service:DigitalImaging:1</serviceType>
      <SCPDURL>/DigitalImagingDesc.xml</SCPDURL></service></serviceList>
      </device></root>''', Uri.parse('http://192.168.122.1:64321/dd.xml'));
      expect(endpoint.model, 'ZV-E10');
      expect(endpoint.id, 'uuid:camera-123');
      expect(endpoint.ptpPort, 15740);
      expect(
        endpoint.capabilityUri.toString(),
        'http://192.168.122.1:64321/DigitalImagingDesc.xml',
      );
      final ready = endpoint.withCapabilities('''<root><X_PTP_Information>
      <X_PTP_Versions>3.00</X_PTP_Versions>
      <X_PTP_MediaServerSupport>Enable</X_PTP_MediaServerSupport>
      <X_PTP_PairingNecessity>Unnecessary</X_PTP_PairingNecessity>
      </X_PTP_Information></root>''');
      expect(ready.mediaServer, isTrue);
      expect(ready.ptpVersion, '3.00');
    },
  );

  test('PC Remote is distinguished from actual media transfer', () {
    final endpoint = SonyCameraEndpoint.manual('192.168.122.1')
        .withCapabilities(
          '<root><X_PTP_MediaServerSupport>Disable</X_PTP_MediaServerSupport></root>',
        );
    expect(endpoint.mediaServer, isFalse);
  });

  test(
    'manual endpoints reject external hosts, credentials and invalid ports',
    () {
      for (final host in [
        '8.8.8.8',
        'example.com',
        '127.0.0.1',
        '0.0.0.0',
        'user@192.168.1.1',
      ]) {
        expect(() => SonyCameraEndpoint.manual(host), throwsArgumentError);
      }
      expect(
        () => SonyCameraEndpoint.manual('192.168.1.1', port: 0),
        throwsArgumentError,
      );
      expect(
        () => SonyCameraEndpoint.manual('192.168.1.1', port: 65536),
        throwsArgumentError,
      );
      expect(SonyCameraEndpoint.manual('192.168.1.1').host, '192.168.1.1');
    },
  );

  test(
    'untrusted XML cannot fetch external entities or cross-camera service URLs',
    () {
      for (final xml in [
        '<!DOCTYPE root [<!ENTITY x SYSTEM "file:///etc/passwd">]><root>&x;</root>',
        '<root><manufacturer>Sony</manufacturer><service><serviceType>urn:schemas-sony-com:service:DigitalImaging:1</serviceType><SCPDURL>http://8.8.8.8/a</SCPDURL></service></root>',
        '<root><manufacturer>Another device</manufacturer></root>',
      ]) {
        expect(
          () => SonyCameraDiscovery.parseDescription(
            xml,
            Uri.parse('http://192.168.1.1/dd.xml'),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'real local HTTP description fetch is bounded and follows no redirects',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        if (request.uri.path == '/redirect') {
          request.response.statusCode = 302;
          request.response.headers.set('Location', 'http://8.8.8.8/');
        } else {
          request.response.write(
            '<root><manufacturer>Sony</manufacturer><modelName>ZV-E10</modelName></root>',
          );
        }
        request.response.close();
      });
      final discovery = SonyCameraDiscovery(allowLoopbackForTesting: true);
      final endpoint = await discovery.readDescription(
        Uri.parse('http://127.0.0.1:${server.port}/dd.xml'),
      );
      expect(endpoint.model, 'ZV-E10');
      await expectLater(
        discovery.readDescription(
          Uri.parse('http://127.0.0.1:${server.port}/redirect'),
        ),
        throwsA(isA<HttpException>()),
      );
    },
  );
}
