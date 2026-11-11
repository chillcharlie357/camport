import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:camport/data/protocol/ptp_codec.dart';
import 'package:camport/data/protocol/ptp_ip_transport.dart';
import 'package:camport/data/sony/sony_ptp_adapter.dart';
import 'package:camport/domain/models/camera_profile.dart';

import 'ptp_ip_transport_test.dart' as tcp show Camera, packet, start, data;

List<int> a16(List<int> v) => [
  ...ptpPackUint32(v.length),
  ...v.expand(ptpPackUint16),
];
List<int> a32(List<int> v) => [
  ...ptpPackUint32(v.length),
  ...v.expand(ptpPackUint32),
];
List<int> str(String v) => ptpPackString(v);
const basicOps = [
  0x1001,
  0x1002,
  0x1004,
  0x1005,
  0x1007,
  0x1008,
  0x1009,
  0x100a,
  0x101b,
  0x9803,
];
const sonyOps = [...basicOps, 0x9210, 0x9201, 0x9202, 0x9212, 0x9219];
Uint8List device(
  List<int> ops, {
  String serial = 'SN123456',
  String manufacturer = 'Sony Corporation',
  String model = 'ILCE-7M3',
}) => Uint8List.fromList([
  ...ptpPackUint16(100),
  ...ptpPackUint32(6),
  ...ptpPackUint16(100),
  ...str('Sony'),
  ...ptpPackUint16(0),
  ...a16(ops),
  ...a16([]),
  ...a16([]),
  ...a16([]),
  ...a16([]),
  ...str(manufacturer),
  ...str(model),
  ...str('1.00'),
  ...str(serial),
]);
Uint8List storage({int free = 100, String label = 'CARD1'}) =>
    Uint8List.fromList([
      ...ptpPackUint16(3),
      ...ptpPackUint16(2),
      ...ptpPackUint16(0),
      ...ptpPackUint64(64000000000),
      ...ptpPackUint64(free),
      ...ptpPackUint32(99),
      ...str('SD Card'),
      ...str(label),
    ]);
Uint8List object(
  int handle,
  int size, {
  int store = 0x10001,
  int parent = 42,
  bool directory = false,
  String modified = '20261111T120000',
}) => Uint8List.fromList([
  ...ptpPackUint32(store),
  ...ptpPackUint16(directory ? 0x3001 : 0x3801),
  ...ptpPackUint16(0),
  ...ptpPackUint32(size > 0xfffffffe ? 0xffffffff : size),
  ...ptpPackUint16(0x3801),
  ...ptpPackUint32(100),
  ...ptpPackUint32(160),
  ...ptpPackUint32(120),
  ...ptpPackUint32(6000),
  ...ptpPackUint32(4000),
  ...ptpPackUint32(24),
  ...ptpPackUint32(parent),
  ...ptpPackUint16(directory ? 1 : 0),
  ...ptpPackUint32(0),
  ...ptpPackUint32(0),
  ...str('DSC_${handle.toString().padLeft(4, '0')}.JPG'),
  ...str('20261110T100000'),
  ...str(modified),
  ...str(''),
]);

class Call {
  Call(this.op, this.params, this.tid, this.cap, this.streaming);
  final int op;
  final List<int> params;
  final int? tid;
  final int cap;
  final bool streaming;
}

class CameraTransport extends PtpIpTransport {
  CameraTransport({List<int> ops = sonyOps}) : ops = List.of(ops);
  List<int> ops;
  final calls = <Call>[];
  String serial = 'SN123456';
  String manufacturer = 'Sony Corporation';
  String model = 'ILCE-7M3';
  int free = 100;
  String label = 'CARD1';
  String modified = '20261111T120000';
  int size = 2 * 1024 * 1024 + 7;
  List<int> stores = [0x10001];
  List<int> handles = [1, 2, 3, 4, 5];
  final directories = <int>{};
  final errors = <int, int>{};
  Uint8List? thumbnail;
  int? failOffset;
  bool shortSuccess = false;
  Completer<void>? block;
  final entered = Completer<void>();
  Completer<void> stopped = Completer<void>();
  bool alive = false;
  int closes = 0;
  @override
  bool get connected => alive;
  @override
  Future<void> connect({
    required String host,
    required int port,
    required Uint8List guid,
    String friendlyName = 'CamPort',
  }) async {
    expect(host, '192.168.122.1');
    expect(port, 15740);
    alive = true;
    stopped = Completer<void>();
  }

  PtpResponse result({
    List<int> bytes = const [],
    int code = 0x2001,
    List<int> parameters = const [],
  }) => PtpResponse(code, parameters, Uint8List.fromList(bytes), bytes.length);
  @override
  Future<PtpResponse> command(
    int operation, {
    List<int> parameters = const [],
    int maxDataBytes = 1024 * 1024,
    IOSink? sink,
    int? transactionId,
  }) async {
    if (!alive) throw StateError('closed');
    calls.add(
      Call(
        operation,
        List.of(parameters),
        transactionId,
        maxDataBytes,
        sink != null,
      ),
    );
    if (errors.containsKey(operation)) return result(code: errors[operation]!);
    switch (operation) {
      case 0x1001:
        return result(
          bytes: device(
            ops,
            serial: serial,
            manufacturer: manufacturer,
            model: model,
          ),
        );
      case 0x1002:
      case 0x9210:
      case 0x9201:
      case 0x9212:
        return result();
      case 0x9202:
        return result(
          bytes: [
            ...ptpPackUint16(300),
            ...a16([0xd201]),
            ...a16([0xd2c1]),
          ],
        );
      case 0x1004:
        return result(bytes: a32(stores));
      case 0x1005:
        return result(
          bytes: storage(free: free, label: label),
        );
      case 0x1007:
        return result(bytes: a32(handles));
      case 0x1008:
        return result(
          bytes: object(
            parameters.first,
            size,
            store: parameters.first == 90 ? 0x20001 : 0x10001,
            directory: directories.contains(parameters.first),
            modified: modified,
          ),
        );
      case 0x9803:
        expect(parameters[1], 0xdc04);
        return result(bytes: ptpPackUint64(size));
      case 0x100a:
        return thumbnail == null
            ? result(code: 0x2010)
            : result(bytes: thumbnail!);
      case 0x9219:
      case 0x9211:
      case 0x101b:
      case 0x1009:
        if (block != null) {
          if (!entered.isCompleted) entered.complete();
          await Future.any([
            block!.future,
            stopped.future.then((_) => throw StateError('closed')),
          ]);
          if (!alive) throw StateError('closed');
        }
        final offset = operation == 0x1009
            ? 0
            : parameters[1] +
                  ((operation == 0x9219 || operation == 0x9211)
                      ? parameters[2] * 0x100000000
                      : 0);
        final requested = operation == 0x1009 ? size : parameters.last;
        final count = shortSuccess ? requested - 1 : requested;
        final bytes = Uint8List.fromList(
          List.generate(count, (i) => (offset + i) % 251),
        );
        if (failOffset == offset) {
          sink!.add(bytes.sublist(0, count ~/ 2));
          await sink.flush();
          return PtpResponse(0x2002, [], Uint8List(0), count ~/ 2);
        }
        if (sink != null) {
          sink.add(bytes);
          await sink.flush();
          return PtpResponse(0x2001, [count], Uint8List(0), count);
        }
        return result(bytes: bytes, parameters: [count]);
      default:
        throw StateError('Unexpected operation ${operation.toRadixString(16)}');
    }
  }

  @override
  Future<void> close() async {
    alive = false;
    closes++;
    if (!stopped.isCompleted) stopped.complete();
  }
}

CameraProfile candidate({
  String host = '192.168.122.1',
  String id = 'manual:camera',
  String? model,
  Map<String, String> extra = const {},
}) => CameraProfile(
  id: id,
  displayName: 'Sony',
  model: model,
  connectionKind: ConnectionKind.cameraAccessPoint,
  connectionConfiguration: {'host': host, 'port': '15740', ...extra},
);

void main() {
  late CameraTransport wire;
  late SonyPtpCameraAdapter adapter;
  late Directory temp;
  setUp(() async {
    wire = CameraTransport();
    adapter = SonyPtpCameraAdapter(guid: Uint8List(16), transport: wire);
    temp = await Directory.systemTemp.createTemp('sony-adapter-');
  });
  tearDown(() async {
    await adapter.close();
    await temp.delete(recursive: true);
  });
  test(
    'real local TCP transport integrates metadata and original transfer',
    () async {
      final camera = await tcp.Camera.create();
      final local = SonyPtpCameraAdapter(
        guid: Uint8List(16),
        transport: LocalTestTransport(camera.server.port),
      );
      final serving = () async {
        await camera.handshake();
        while (true) {
          final frame = ByteData.sublistView(await camera.command!.frame());
          final op = frame.getUint16(12, Endian.little);
          final tid = frame.getUint32(14, Endian.little);
          final bytes = switch (op) {
            0x1001 => device(basicOps),
            0x1002 => <int>[],
            0x1004 => a32([0x10001]),
            0x1005 => storage(),
            0x1008 => object(1, 17),
            0x101b => List.generate(17, (i) => i),
            _ => throw StateError('Unexpected local wire operation $op'),
          };
          await camera.command!.send([
            if (bytes.isNotEmpty) ...[
              ...tcp.start(tid, bytes.length),
              ...tcp.data(tid, bytes, end: true),
            ],
            ...tcp.packet(7, [
              ...ptpPackUint16(0x2001),
              ...ptpPackUint32(tid),
              if (op == 0x101b) ...ptpPackUint32(17),
            ]),
          ]);
          if (op == 0x101b) break;
        }
      }();
      try {
        await local.connect(candidate());
        final part = File('${temp.path}/tcp.part');
        await local
            .downloadOriginal('00010001:00000001', part.path)
            .drain<void>();
        expect(await part.readAsBytes(), List.generate(17, (i) => i));
        await serving;
      } finally {
        await local.close();
        await camera.close();
      }
    },
  );

  test(
    'Sony exact contents handshake, session zero TID and truthful capabilities',
    () async {
      final profile = await adapter.connect(candidate());
      expect(wire.calls.take(8).map((c) => c.op), [
        0x1001,
        0x9210,
        0x9201,
        0x9201,
        0x9202,
        0x9201,
        0x9212,
        0x1004,
      ]);
      expect(wire.calls[0].tid, 0);
      expect(wire.calls[1].tid, 0);
      expect(wire.calls[1].params, [1, 1]);
      expect(wire.calls[2].params, [1, 0, 0]);
      expect(wire.calls[3].params, [2, 0, 0]);
      expect(wire.calls[4].params, [300]);
      expect(wire.calls[5].params, [3, 0, 0]);
      expect(wire.calls[6].params, [2, 1, 0]);
      expect(profile.id, isNot('manual:camera'));
      expect(profile.connectionConfiguration['host'], '192.168.122.1');
      expect(adapter.cacheNamespace, isNotNull);
      final caps = await adapter.discoverCapabilities();
      expect(caps.canListFiles, isTrue);
      expect(caps.canDownloadOriginals, isTrue);
      expect(caps.canRemoteControl, isFalse);
    },
  );
  test('ordinary Sony PTP uses standard session and does not invent thumbnail support', () async {
    wire.ops = basicOps.where((o) => o != 0x100a).toList();
    await adapter.connect(candidate());
    expect(wire.calls[1].op, 0x1002);
    expect(wire.calls[1].params, [1]);
    expect(wire.calls.any((c) => c.op >= 0x9200 && c.op < 0x9300), isFalse);
    expect((await adapter.discoverCapabilities()).hasThumbnails, isFalse);
  });
  test('mediaServer flag permits Sony session negotiation even if operation not listed', () async {
    wire.ops = basicOps;
    await adapter.connect(candidate(extra: {'mediaServer': 'true'}));
    expect(wire.calls[1].op, 0x9210);
    expect((await adapter.discoverCapabilities()).canDownloadOriginals, isTrue);
  });
  test('manual ZV-E10 tries contents while standard session fallback handles unsupported SDIO', () async {
    wire.ops = basicOps;
    wire.model = 'ZV-E10';
    wire.errors[0x9210] = 0x2005;
    await adapter.connect(candidate(model: 'ZV-E10'));
    expect(wire.calls[1].op, 0x9210);
    expect(wire.calls[2].op, 0x1002);
    expect(wire.calls.any((c) => c.op == 0x9212), isTrue);
  });
  for (final host in [
    '8.8.8.8',
    'localhost',
    '127.0.0.1',
    '::1',
    '192.168.1.1.evil',
  ]) {
    test('reject non-LAN IPv4 $host even with injected transport', () async {
      await expectLater(
        adapter.connect(candidate(host: host)),
        throwsArgumentError,
      );
      expect(wire.calls, isEmpty);
    });
  }
  test(
    'rejects non Sony and PC Remote endpoints with actionable Chinese reason',
    () async {
      wire.manufacturer = 'Other';
      await expectLater(
        adapter.connect(candidate()),
        throwsA(predicate((e) => '$e'.contains('Sony'))),
      );
      wire.manufacturer = 'Sony';
      wire.stores = [];
      await expectLater(
        adapter.connect(candidate()),
        throwsA(
          predicate(
            (e) => '$e'.contains('PC Remote') && '$e'.contains('Smartphone'),
          ),
        ),
      );
    },
  );
  test(
    'unsupported contents mode is rejected rather than exposing PC Remote',
    () async {
      wire.errors[0x9212] = 0x2005;
      await expectLater(
        adapter.connect(candidate()),
        throwsA(predicate((e) => '$e'.contains('PC Remote'))),
      );
      expect(adapter.connected, isFalse);
    },
  );
  test(
    'lazy metadata pagination skips associations and invalidates old cursor',
    () async {
      wire.handles = List.generate(25, (i) => i + 1);
      wire.directories.add(1);
      await adapter.connect(candidate());
      expect(wire.calls.where((c) => c.op == 0x1008), isEmpty);
      final first = await adapter.listFiles();
      expect(first.items, hasLength(20));
      expect(first.items.first.id, '00010001:00000002');
      expect(first.items.first.directory, contains(adapter.profile!.id));
      expect(wire.calls.where((c) => c.op == 0x1008), hasLength(21));
      final last = await adapter.listFiles(cursor: first.nextCursor);
      expect(last.items, hasLength(4));
      expect(last.nextCursor, isNull);
      await adapter.close();
      await adapter.connect(candidate());
      await expectLater(
        adapter.listFiles(cursor: first.nextCursor),
        throwsA(anything),
      );
    },
  );
  test('stable revision ignores free space and address, changes on metadata or storage', () async {
    await adapter.connect(candidate());
    final p = adapter.profile!.id;
    final ns = adapter.cacheNamespace;
    final a = await adapter.describeFile('00010001:00000001');
    wire.free = 1;
    await adapter.close();
    await adapter.connect(candidate());
    expect(adapter.profile!.id, p);
    expect(adapter.cacheNamespace, ns);
    expect((await adapter.describeFile(a.id)).thumbnailKey, a.thumbnailKey);
    wire.modified = '20261111T130000';
    expect(
      (await adapter.describeFile(a.id)).thumbnailKey,
      isNot(a.thumbnailKey),
    );
    wire.modified = '20261111T120000';
    wire.label = 'CARD2';
    expect(
      (await adapter.describeFile(a.id)).thumbnailKey,
      isNot(a.thumbnailKey),
    );
  });
  test(
    'weak serial uses UDN or remains unverified with ephemeral scope',
    () async {
      wire.serial = '00000000';
      await adapter.connect(candidate());
      final weak = adapter.profile!.id;
      expect(adapter.cacheNamespace, isNull);
      await adapter.close();
      await adapter.connect(candidate());
      expect(adapter.profile!.id, isNot(weak));
      await adapter.close();
      final udn = candidate(id: 'uuid:00112233-4455-6677-8899-aabbccddeeff');
      await adapter.connect(udn);
      expect(adapter.cacheNamespace, isNotNull);
    },
  );
  test(
    'UDN identity survives reconnect using the returned saved profile',
    () async {
      wire.serial = '';
      final saved = await adapter.connect(
        candidate(id: 'uuid:00112233-4455-6677-8899-aabbccddeeff'),
      );
      final namespace = adapter.cacheNamespace;
      await adapter.close();
      final resumed = await adapter.connect(saved);
      expect(resumed.id, saved.id);
      expect(adapter.cacheNamespace, namespace);
      expect(
        resumed.connectionConfiguration['udn'],
        'uuid:00112233-4455-6677-8899-aabbccddeeff',
      );
    },
  );
  test(
    'storage protocol error explains Smartphone contents connection',
    () async {
      wire.errors[0x1004] = 0x2013;
      await expectLater(
        adapter.connect(candidate()),
        throwsA(
          predicate(
            (e) => '$e'.contains('PC Remote') && '$e'.contains('Smartphone'),
          ),
        ),
      );
    },
  );

  test(
    'large sentinel size uses UInt64 property and rejects unverified size',
    () async {
      wire.size = 0x100000000 + 99;
      await adapter.connect(candidate());
      expect(
        (await adapter.describeFile('00010001:00000001')).byteLength,
        wire.size,
      );
      expect(wire.calls.last.params, [1, 0xdc04]);
      await adapter.close();
      wire.ops.remove(0x9803);
      await adapter.connect(candidate());
      await expectLater(
        adapter.describeFile('00010001:00000001'),
        throwsA(predicate((e) => '$e'.contains('大小'))),
      );
    },
  );
  test(
    'NoThumbnail never falls back to original and thumbnail cap is 2MiB',
    () async {
      await adapter.connect(candidate());
      expect(await adapter.loadThumbnail('00010001:00000001'), isNull);
      expect(wire.calls.last.op, 0x100a);
      expect(wire.calls.last.cap, 2 * 1024 * 1024);
      expect(wire.calls.any((c) => c.op == 0x1009), isFalse);
    },
  );
  test(
    'oversized preview is resized in isolation and RAW signatures are rejected',
    () async {
      await adapter.connect(candidate());
      wire.thumbnail = img.encodeJpg(img.Image(width: 1000, height: 600));
      final bytes = await adapter.loadThumbnail('00010001:00000001');
      expect(bytes, isNotNull);
      final decoded = img.decodeJpg(bytes!)!;
      expect(decoded.width, 512);
      expect(decoded.height, lessThanOrEqualTo(512));
      wire.thumbnail = Uint8List.fromList([0x49, 0x49, 0x2a, 0, 1, 2, 3]);
      expect(await adapter.loadThumbnail('00010001:00000001'), isNull);
    },
  );
  test('resume uses actual part length and known source bytes with 1MiB large chunks', () async {
    await adapter.connect(candidate());
    final meta = await adapter.describeFile('00010001:00000001');
    adapter.expectFile(
      meta.id,
      sourceVersion: meta.thumbnailKey,
      byteLength: meta.byteLength,
    );
    final part = File('${temp.path}/image.part');
    await part.writeAsBytes(List.generate(23, (i) => i % 251));
    final updates = await adapter.downloadOriginal(meta.id, part.path).toList();
    final chunks = wire.calls.where((c) => c.op == 0x9219).toList();
    expect(chunks.first.params, [1, 23, 0, 1024 * 1024]);
    expect(chunks.every((c) => c.streaming), isTrue);
    expect(wire.calls.any((c) => c.op == 0x9211), isFalse);
    expect(updates.last.bytesTransferred, wire.size);
    expect(await part.length(), wire.size);
    final content = await part.readAsBytes();
    expect(
      content.asMap().entries.every((e) => e.value == e.key % 251),
      isTrue,
    );
  });
  test('failed chunk rolls file back to last committed progress', () async {
    wire.failOffset = 1024 * 1024;
    await adapter.connect(candidate());
    final part = File('${temp.path}/image.part');
    await expectLater(
      adapter.downloadOriginal('00010001:00000001', part.path).toList(),
      throwsA(anything),
    );
    expect(await part.length(), 1024 * 1024);
  });
  test('legacy 0x9211 chunked download is used when 0x9219 is absent', () async {
    wire.ops.remove(0x9219);
    wire.ops.add(0x9211);
    await adapter.connect(candidate());
    final part = File('${temp.path}/legacy.part');
    await adapter
        .downloadOriginal('00010001:00000001', part.path)
        .drain<void>();
    expect(wire.calls.any((c) => c.op == 0x9211), isTrue);
    expect(wire.calls.any((c) => c.op == 0x9219), isFalse);
    expect(await part.readAsBytes(), List.generate(wire.size, (i) => i % 251));
  });
  test('source revision change refuses queued file before writing', () async {
    await adapter.connect(candidate());
    final meta = await adapter.describeFile('00010001:00000001');
    adapter.expectFile(
      meta.id,
      sourceVersion: meta.thumbnailKey,
      byteLength: meta.byteLength,
    );
    wire.modified = '20261111T130000';
    final part = File('${temp.path}/image.part');
    await part.writeAsBytes([1, 2, 3]);
    await expectLater(
      adapter.downloadOriginal(meta.id, part.path).toList(),
      throwsA(anything),
    );
    expect(await part.readAsBytes(), [1, 2, 3]);
    expect(wire.calls.any((c) => c.op == 0x9219), isFalse);
  });
  test(
    '32-bit partial fallback is negotiated, short video opcode never used',
    () async {
      wire.ops.remove(0x9219);
      wire.size = 17;
      await adapter.connect(candidate());
      final part = File('${temp.path}/image.part');
      await part.writeAsBytes([0, 1, 2]);
      await adapter
          .downloadOriginal('00010001:00000001', part.path)
          .drain<void>();
      expect(wire.calls.last.op, 0x101b);
      expect(wire.calls.last.params, [1, 3, 14]);
    },
  );
  test('GetObject-only capability restarts partial file instead of claiming resume', () async {
    wire.ops.removeWhere((op) => op == 0x9219 || op == 0x101b);
    wire.size = 17;
    await adapter.connect(candidate());
    final part = File('${temp.path}/image.part');
    await part.writeAsBytes([99, 99, 99]);
    await adapter
        .downloadOriginal('00010001:00000001', part.path)
        .drain<void>();
    expect(wire.calls.last.op, 0x1009);
    expect(wire.calls.last.streaming, isTrue);
    expect(await part.readAsBytes(), List.generate(17, (i) => i));
  });
  test(
    'already complete partial emits verified completion without transfer',
    () async {
      wire.size = 7;
      await adapter.connect(candidate());
      final part = File('${temp.path}/complete.part');
      await part.writeAsBytes(List.generate(7, (i) => i));
      final progress = await adapter
          .downloadOriginal('00010001:00000001', part.path)
          .toList();
      expect(progress, hasLength(1));
      expect(progress.single.bytesTransferred, 7);
      expect(wire.calls.any((c) => c.op == 0x9219 || c.op == 0x1009), isFalse);
    },
  );
  test(
    'short successful response rolls back rather than advancing offset',
    () async {
      wire.size = 15;
      wire.shortSuccess = true;
      await adapter.connect(candidate());
      final part = File('${temp.path}/short.part');
      await part.writeAsBytes([0, 1, 2]);
      await expectLater(
        adapter.downloadOriginal('00010001:00000001', part.path).toList(),
        throwsFormatException,
      );
      expect(await part.readAsBytes(), [0, 1, 2]);
    },
  );
  test(
    'unsupported large partial falls back only to advertised standard partial',
    () async {
      wire.size = 15;
      wire.errors[0x9219] = 0x2005;
      await adapter.connect(candidate());
      final part = File('${temp.path}/fallback.part');
      await part.writeAsBytes([0, 1, 2]);
      await adapter
          .downloadOriginal('00010001:00000001', part.path)
          .drain<void>();
      expect(wire.calls.last.op, 0x101b);
      expect(wire.calls.last.params, [1, 3, 12]);
      expect(await part.readAsBytes(), List.generate(15, (i) => i));
    },
  );
  test(
    'unrepresentable standard-partial offset refuses without truncating',
    () async {
      wire.ops.removeWhere((op) => op == 0x9219 || op == 0x1009);
      wire.size = 0x100000020;
      await adapter.connect(candidate());
      final part = File('${temp.path}/large.part');
      final handle = await part.open(mode: FileMode.write);
      await handle.truncate(0x100000009);
      await handle.close();
      await expectLater(
        adapter.downloadOriginal('00010001:00000001', part.path).toList(),
        throwsUnsupportedError,
      );
      expect(await part.length(), 0x100000009);
      expect(wire.calls.any((c) => c.op == 0x101b), isFalse);
    },
  );
  test(
    'queued byte-length mismatch rejects before touching the part file',
    () async {
      await adapter.connect(candidate());
      adapter.expectFile('00010001:00000001', byteLength: 999);
      final part = File('${temp.path}/changed.part');
      await part.writeAsBytes([7]);
      await expectLater(
        adapter.downloadOriginal('00010001:00000001', part.path).drain<void>(),
        throwsStateError,
      );
      expect(await part.readAsBytes(), [7]);
    },
  );
  test('pixel bomb header is rejected before image decoding', () async {
    await adapter.connect(candidate());
    final header = ByteData(24);
    header.setUint32(0, 0x89504e47);
    header.setUint32(4, 0x0d0a1a0a);
    header.setUint32(8, 13);
    header.setUint32(12, 0x49484452);
    header.setUint32(16, 100000);
    header.setUint32(20, 100000);
    wire.thumbnail = header.buffer.asUint8List();
    expect(await adapter.loadThumbnail('00010001:00000001'), isNull);
  });

  test(
    '64-bit resume keeps high offset and does not truncate beyond 4GiB',
    () async {
      final offset = 0x100000000 + 9;
      wire.size = offset + 7;
      await adapter.connect(candidate());
      final part = File('${temp.path}/large.part');
      final f = await part.open(mode: FileMode.write);
      await f.truncate(offset);
      await f.close();
      await adapter
          .downloadOriginal('00010001:00000001', part.path)
          .drain<void>();
      expect(wire.calls.last.params, [1, 9, 1, 7]);
      expect(await part.length(), offset + 7);
    },
  );
  test('symlink part is rejected without touching target', () async {
    await adapter.connect(candidate());
    final target = File('${temp.path}/target');
    await target.writeAsString('safe');
    final link = Link('${temp.path}/image.part');
    await link.create(target.path);
    await expectLater(
      adapter.downloadOriginal('00010001:00000001', link.path).drain<void>(),
      throwsA(anything),
    );
    expect(await target.readAsString(), 'safe');
  });
  test('cancel immediately closes transport and suppresses completion or late writes', () async {
    wire.block = Completer<void>();
    await adapter.connect(candidate());
    final part = File('${temp.path}/image.part');
    var updates = 0;
    var done = false;
    final sub = adapter
        .downloadOriginal('00010001:00000001', part.path)
        .listen(
          (_) => updates++,
          onDone: () => done = true,
          onError: (Object _) {},
        );
    await wire.entered.future;
    await sub.cancel().timeout(const Duration(seconds: 1));
    expect(wire.connected, isFalse);
    final length = await part.length();
    wire.block!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(await part.length(), length);
    expect(done, isFalse);
    expect(updates, 0);
  });
}

// The production adapter still validates a LAN IPv4. Only this injected test
// transport redirects the socket to a loopback virtual camera.
class LocalTestTransport extends PtpIpTransport {
  LocalTestTransport(this.port) : super(keepAliveInterval: null);
  final int port;
  @override
  Future<void> connect({
    required String host,
    required int port,
    required Uint8List guid,
    String friendlyName = 'CamPort',
  }) => super.connect(
    host: '127.0.0.1',
    port: this.port,
    guid: guid,
    friendlyName: friendlyName,
  );
}
