import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sony_camera/platform/transfer_background.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/transfer_background');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late TransferBackground background;
  late List<MethodCall> calls;

  Future<void> event(Object? value, {String method = 'event'}) async {
    final response = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method, value)),
      (_) => response.complete(),
    );
    await response.future;
  }

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    background = TransferBackground(channel: channel);
  });

  tearDown(() async {
    await background.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('uses the shared native channel by default', () async {
    const native = MethodChannel('sony_camera/transfer_background');
    messenger.setMockMethodCallHandler(native, (call) async {
      expect(call.method, 'stop');
      return null;
    });
    final defaultBridge = TransferBackground();
    await defaultBridge.stop();
    await defaultBridge.dispose();
    messenger.setMockMethodCallHandler(native, null);
  });

  test('forwards start, known and unknown progress, and stop', () async {
    await background.start(pendingFiles: 3);
    await background.update(filename: 'DSC00001.ARW', bytes: 42, total: 100);
    await background.update(filename: 'DSC00002.JPG', bytes: 8);
    await background.stop();
    expect(calls.map((call) => call.method), [
      'start',
      'update',
      'update',
      'stop',
    ]);
    expect(calls[0].arguments, {'pendingFiles': 3});
    expect(calls[1].arguments, {
      'filename': 'DSC00001.ARW',
      'bytes': 42,
      'total': 100,
    });
    expect(calls[2].arguments, {
      'filename': 'DSC00002.JPG',
      'bytes': 8,
      'total': null,
    });
    expect(calls[3].arguments, isNull);
  });

  test(
    'reports notification denial without claiming a visible notification',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'notificationsEnabled': false,
          'notificationStatus': 'permissionDenied',
          'message':
              'Foreground service active; notification permission denied.',
        },
      );
      await background.start(pendingFiles: 1);
      expect(background.notificationsEnabled, isFalse);
      expect(background.notificationStatus, 'permissionDenied');
      expect(background.statusMessage, contains('permission denied'));
    },
  );

  test('broadcasts all native events to multiple listeners', () async {
    final first = <BackgroundTransferEvent>[];
    final second = <BackgroundTransferEvent>[];
    final a = background.events.listen(first.add);
    final b = background.events.listen(second.add);
    for (final value in BackgroundTransferEvent.values) {
      await event(value.name);
    }
    expect(first, BackgroundTransferEvent.values);
    expect(second, first);
    await a.cancel();
    await b.cancel();
  });

  test(
    'ignores unrecognized events without fabricating a control event',
    () async {
      final events = <BackgroundTransferEvent>[];
      final subscription = background.events.listen(events.add);
      await event('futureEvent');
      await event({'invalid': true});
      expect(events, isEmpty);
      await subscription.cancel();
    },
  );

  test(
    'forwards Wi-Fi loss so the runner can pause its persisted queue',
    () async {
      final next = background.events.first;
      await event('networkLost');
      expect(await next, BackgroundTransferEvent.networkLost);
    },
  );

  test('forwards Wi-Fi preparation result and user settings actions', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'prepareNetwork'
          ? {
              'connected': true,
              'message': 'Wi-Fi ready',
              'host': '192.168.122.1',
            }
          : null;
    });
    expect(await background.prepareNetwork(), {
      'connected': true,
      'message': 'Wi-Fi ready',
      'host': '192.168.122.1',
    });
    await background.releaseNetwork();
    await background.openWifiSettings();
    expect(calls.map((call) => call.method), [
      'prepareNetwork',
      'releaseNetwork',
      'openWifiSettings',
    ]);
  });

  test('preserves disconnected Wi-Fi instructions', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'connected': false,
        'message': 'Join the camera DIRECT network in Wi-Fi settings.',
      },
    );
    expect((await background.prepareNetwork())['connected'], isFalse);
  });

  test('rejects malformed network results', () async {
    await expectLater(
      background.prepareNetwork(),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'missing implementation explicitly fails every platform operation',
    () async {
      messenger.setMockMethodCallHandler(channel, null);
      for (final operation in <Future<Object?> Function()>[
        () => background.start(pendingFiles: 1),
        () => background.update(filename: 'a.jpg', bytes: 1),
        background.stop,
        background.prepareNetwork,
        background.releaseNetwork,
        background.openWifiSettings,
      ]) {
        await expectLater(
          operation(),
          throwsA(
            isA<UnsupportedError>().having(
              (error) => error.message,
              'message',
              contains('not available'),
            ),
          ),
        );
      }
    },
  );

  test('preserves native failure details', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'foreground_start_failed',
        message: 'OS refused',
        details: 31,
      );
    });
    await expectLater(
      background.start(pendingFiles: 1),
      throwsA(
        isA<PlatformException>()
            .having((error) => error.code, 'code', 'foreground_start_failed')
            .having((error) => error.details, 'details', 31),
      ),
    );
  });

  test(
    'rejects invalid progress and empty queues before native calls',
    () async {
      await expectLater(background.start(pendingFiles: 0), throwsArgumentError);
      await expectLater(
        background.update(filename: '', bytes: 1),
        throwsArgumentError,
      );
      await expectLater(
        background.update(filename: 'a', bytes: -1),
        throwsArgumentError,
      );
      await expectLater(
        background.update(filename: 'a', bytes: 1, total: -1),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    },
  );
}
