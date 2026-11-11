import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:camport/data/protocol/ptp_codec.dart';
import 'package:camport/data/protocol/ptp_ip_transport.dart';

Uint8List u16(int n) =>
    (ByteData(2)..setUint16(0, n, Endian.little)).buffer.asUint8List();
Uint8List u32(int n) =>
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List();
Uint8List u64(int n) =>
    (ByteData(8)..setUint64(0, n, Endian.little)).buffer.asUint8List();
int at32(List<int> b, int p) =>
    ByteData.sublistView(Uint8List.fromList(b)).getUint32(p, Endian.little);
List<int> name(String s) => [...s.codeUnits.expand(u16), 0, 0];
List<int> packet(int type, List<int> body) => [
  ...u32(body.length + 8),
  ...u32(type),
  ...body,
];
List<int> response(int tid, {int code = 0x2001}) =>
    packet(7, [...u16(code), ...u32(tid)]);
List<int> start(int tid, int size) => packet(9, [...u32(tid), ...u64(size)]);
List<int> data(int tid, List<int> bytes, {bool end = false}) =>
    packet(end ? 12 : 10, [...u32(tid), ...bytes]);

class Peer {
  Peer(this.socket) : it = StreamIterator(socket);
  final Socket socket;
  final StreamIterator<Uint8List> it;
  final List<int> buffer = [];
  Future<Uint8List> read(int n) async {
    while (buffer.length < n) {
      if (!await it.moveNext()) throw StateError('peer disconnected');
      buffer.addAll(it.current);
    }
    final result = Uint8List.fromList(buffer.sublist(0, n));
    buffer.removeRange(0, n);
    return result;
  }

  Future<Uint8List> frame() async {
    final header = await read(8);
    return Uint8List.fromList([...header, ...await read(at32(header, 0) - 8)]);
  }

  Future<void> send(List<int> bytes, {bool fragmented = false}) async {
    if (!fragmented) {
      socket.add(bytes);
      await socket.flush();
    } else {
      for (final b in bytes) {
        socket.add([b]);
        await socket.flush();
        await Future<void>.delayed(Duration.zero);
      }
    }
  }
}

class Camera {
  Camera._(this.server) {
    accepts = StreamIterator(server);
  }
  final ServerSocket server;
  late final StreamIterator<Socket> accepts;
  Peer? command;
  Peer? event;
  Uint8List? init;
  static Future<Camera> create() async =>
      Camera._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
  Future<void> handshake({
    bool fragmented = false,
    List<int>? ack,
    List<int>? eventAck,
  }) async {
    await accepts.moveNext();
    command = Peer(accepts.current);
    init = await command!.frame();
    await command!.send(
      ack ??
          packet(2, [
            ...u32(77),
            ...List.filled(16, 9),
            ...name('Sony'),
            ...u32(0x10000),
          ]),
      fragmented: fragmented,
    );
    if (ack != null) return;
    await accepts.moveNext();
    event = Peer(accepts.current);
    expect(await event!.frame(), packet(3, u32(77)));
    await event!.send(eventAck ?? packet(4, []), fragmented: fragmented);
  }

  Future<void> close() async {
    command?.socket.destroy();
    event?.socket.destroy();
    await accepts.cancel();
    await server.close();
  }
}

void main() {
  late Camera camera;
  late PtpIpTransport transport;
  Future<void> connect({bool fragmented = false}) async {
    await Future.wait([
      camera.handshake(fragmented: fragmented),
      transport.connect(
        host: '127.0.0.1',
        port: camera.server.port,
        guid: Uint8List.fromList(List.generate(16, (i) => i)),
        friendlyName: '索尼📷',
      ),
    ]);
  }

  setUp(() async {
    camera = await Camera.create();
    transport = PtpIpTransport(
      timeout: const Duration(seconds: 2),
      keepAliveInterval: null,
    );
  });
  tearDown(() async {
    await transport.close();
    await camera.close();
  });

  test(
    'codec LE values, surrogate strings, bounded arrays and truncated input',
    () {
      final reader = PtpReader(
        Uint8List.fromList([
          ...ptpPackUint16(0x1234),
          ...ptpPackUint32(0x89abcdef),
          ...ptpPackUint64(0x123456789),
          ...ptpPackString('📷索尼'),
          ...u32(2),
          ...u16(1),
          ...u16(65535),
          ...u32(1),
          ...u32(0xabcdef01),
        ]),
      );
      expect(reader.uint16(), 0x1234);
      expect(reader.uint32(), 0x89abcdef);
      expect(reader.uint64(), 0x123456789);
      expect(reader.ptpString(), '📷索尼');
      expect(reader.arrays16(), [1, 65535]);
      expect(reader.arrays32(), [0xabcdef01]);
      expect(reader.remaining, 0);
      expect(reader.uint16, throwsFormatException);
      expect(
        () => PtpReader(Uint8List.fromList(u32(0xffffffff))).arrays32(),
        throwsFormatException,
      );
      expect(
        () => PtpReader(Uint8List.fromList([2, 0, 0])).ptpString(),
        throwsFormatException,
      );
      expect(
        () => PtpReader(Uint8List.fromList([2, 0, 0xd8, 0, 0])).ptpString(),
        throwsFormatException,
      );
    },
  );

  for (final malformed in ['type', 'length', 'version', 'name', 'surrogate']) {
    test('rejects malformed command handshake: $malformed', () async {
      final normal = [
        ...u32(77),
        ...List.filled(16, 9),
        ...name('Sony'),
        ...u32(0x10000),
      ];
      final ack = switch (malformed) {
        'type' => packet(5, u32(1)),
        'length' => packet(2, u32(77)),
        'version' => packet(2, [
          ...normal.sublist(0, normal.length - 4),
          ...u32(0x20000),
        ]),
        'name' => packet(2, [
          ...u32(77),
          ...List.filled(16, 9),
          ...u16(65),
          ...u32(0x10000),
        ]),
        _ => packet(2, [
          ...u32(77),
          ...List.filled(16, 9),
          ...u16(0xd800),
          0,
          0,
          ...u32(0x10000),
        ]),
      };
      await Future.wait([
        camera.handshake(ack: ack),
        expectLater(
          transport.connect(
            host: '127.0.0.1',
            port: camera.server.port,
            guid: Uint8List(16),
          ),
          throwsFormatException,
        ),
      ]);
      expect(transport.connected, isFalse);
    });
  }

  test(
    'rejects malformed event handshake without making connection reusable',
    () async {
      await Future.wait([
        camera.handshake(eventAck: packet(4, [1])),
        expectLater(
          transport.connect(
            host: '127.0.0.1',
            port: camera.server.port,
            guid: Uint8List(16),
          ),
          throwsFormatException,
        ),
      ]);
      expect(transport.connected, isFalse);
      await expectLater(transport.command(0x1001), throwsStateError);
    },
  );

  test('close interrupts an unfinished handshake', () async {
    final connecting = expectLater(
      transport.connect(
        host: '127.0.0.1',
        port: camera.server.port,
        guid: Uint8List(16),
      ),
      throwsStateError,
    );
    await camera.accepts.moveNext();
    camera.command = Peer(camera.accepts.current);
    await camera.command!.frame();
    await transport.close();
    await connecting.timeout(const Duration(milliseconds: 250));
  });

  test('command argument errors do not poison a valid connection', () async {
    await connect();
    await expectLater(
      transport.command(0x1001, parameters: List.filled(6, 0)),
      throwsArgumentError,
    );
    await expectLater(
      transport.command(0x1001, parameters: [-1]),
      throwsRangeError,
    );
    await expectLater(
      transport.command(0x1001, transactionId: -1),
      throwsRangeError,
    );
    expect(transport.connected, isTrue);
  });

  test(
    'fragmented handshake preserves caller wire GUID, UTF16LE and version',
    () async {
      await connect(fragmented: true);
      expect(transport.connected, isTrue);
      expect(at32(camera.init!, 4), 1);
      expect(camera.init!.sublist(8, 24), List.generate(16, (i) => i));
      expect(camera.init!.sublist(24), [...name('索尼📷'), ...u32(0x10000)]);
    },
  );

  test(
    'serializes concurrent commands, phase 1 and explicit zero transaction',
    () async {
      await connect();
      final serving = () async {
        for (final tid in [0, 1, 2]) {
          final p = await camera.command!.frame();
          expect(at32(p, 8), 1);
          expect(at32(p, 14), tid);
          expect(p.length, 22);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(camera.command!.buffer, isEmpty);
          await camera.command!.send(response(tid));
        }
      }();
      final results = await Future.wait([
        transport.command(0x1001, transactionId: 0, parameters: [5]),
        transport.command(0x1002, parameters: [1]),
        transport.command(0x1003, parameters: [2]),
      ]);
      await serving;
      expect(results.map((r) => r.code), everyElement(0x2001));
    },
  );

  test(
    'StartData/Data/EndData and response in one chunk, including end payload',
    () async {
      await connect();
      final serving = () async {
        await camera.command!.frame();
        await camera.command!.send([
          ...start(1, 5),
          ...data(1, [1, 2]),
          ...data(1, [3, 4, 5], end: true),
          ...response(1),
        ]);
      }();
      final result = await transport.command(0x1008);
      await serving;
      expect(result.data, [1, 2, 3, 4, 5]);
      expect(result.receivedBytes, 5);
    },
  );

  test(
    'fragmented data transaction and PTP error responses remain usable',
    () async {
      await connect();
      final serving = () async {
        await camera.command!.frame();
        await camera.command!.send([
          ...start(1, 2),
          ...data(1, [4, 5], end: true),
          ...response(1, code: 0x2019),
        ], fragmented: true);
        await camera.command!.frame();
        await camera.command!.send(
          packet(7, [...u16(0x2002), ...u32(2), ...u32(42)]),
        );
      }();
      expect((await transport.command(0x1008)).code, 0x2019);
      final result = await transport.command(0x1008);
      expect(result.code, 0x2002);
      expect(result.parameters, [42]);
      expect(transport.connected, isTrue);
      await serving;
    },
  );

  test(
    'metadata cap aborts immediately on StartData without reading original',
    () async {
      await connect();
      final serving = () async {
        await camera.command!.frame();
        await camera.command!.send(start(1, 999999999));
      }();
      await expectLater(
        transport.command(0x1008, maxDataBytes: 8),
        throwsFormatException,
      );
      await serving;
      expect(transport.connected, isFalse);
      await expectLater(transport.command(0x1001), throwsStateError);
    },
  );

  test(
    'streams a large single data packet in bounded writes with backpressure',
    () async {
      await connect();
      const size = 5 * 1024 * 1024 + 13;
      final consumer = SlowConsumer();
      final sink = IOSink(consumer);
      final serving = () async {
        await camera.command!.frame();
        await camera.command!.send(start(1, size));
        await camera.command!.send([...u32(size + 12), ...u32(12), ...u32(1)]);
        var sent = 0;
        while (sent < size) {
          final n = (size - sent).clamp(0, 16384);
          camera.command!.socket.add(
            List<int>.generate(n, (i) => (sent + i) % 251),
          );
          sent += n;
          await camera.command!.socket.flush();
        }
        await camera.command!.send(response(1));
      }();
      final result = await transport.command(
        0x1009,
        maxDataBytes: size,
        sink: sink,
      );
      expect(result.data, isEmpty);
      expect(result.receivedBytes, size);
      expect(consumer.bytes, size);
      expect(consumer.largest, lessThanOrEqualTo(65536));
      expect(consumer.valid, isTrue);
      await sink.close();
      await serving;
    },
  );

  for (final scenario in [
    'short header',
    'oversized',
    'wrong tid',
    'overflow',
    'short total',
    'data before start',
    'response before end',
    'double start',
    'double response',
    'bad response params',
    'short start',
    'short data',
    'wrong data tid',
    'wrong start tid',
    'duplicate end',
    'unrepresentable total',
  ]) {
    test('rejects $scenario and closes connection', () async {
      await connect();
      final serving = () async {
        await camera.command!.frame();
        final bytes = switch (scenario) {
          'short header' => [...u32(7), ...u32(7)],
          'oversized' => [...u32(0xffffffff), ...u32(12)],
          'wrong tid' => response(2),
          'short start' => packet(9, u32(1)),
          'short data' => [...start(1, 0), ...packet(12, [])],
          'wrong data tid' => [...start(1, 0), ...data(2, [], end: true)],
          'wrong start tid' => start(2, 0),
          'duplicate end' => [
            ...start(1, 0),
            ...data(1, [], end: true),
            ...data(1, [], end: true),
          ],
          'unrepresentable total' => packet(9, [
            ...u32(1),
            ...List.filled(8, 255),
          ]),
          'overflow' => [
            ...start(1, 1),
            ...data(1, [1, 2], end: true),
          ],
          'short total' => [
            ...start(1, 2),
            ...data(1, [1], end: true),
          ],
          'data before start' => data(1, [1], end: true),
          'response before end' => [
            ...start(1, 1),
            ...data(1, [1]),
            ...response(1),
          ],
          'double start' => [...start(1, 1), ...start(1, 1)],
          'double response' => [...response(1), ...response(1)],
          _ => packet(7, [...u16(0x2001), ...u32(1), 0]),
        };
        await camera.command!.send(bytes);
      }();
      await expectLater(transport.command(0x1008), throwsFormatException);
      await serving;
      expect(transport.connected, isFalse);
    });
  }

  test('zero-length data still requires EndData before response', () async {
    await connect();
    final serving = () async {
      await camera.command!.frame();
      await camera.command!.send([
        ...start(1, 0),
        ...data(1, [], end: true),
        ...response(1),
      ]);
    }();
    expect((await transport.command(0x1009)).receivedBytes, 0);
    await serving;
  });

  test('streaming cap applies to sinks before any write', () async {
    await connect();
    final consumer = SlowConsumer();
    final sink = IOSink(consumer);
    final serving = () async {
      await camera.command!.frame();
      await camera.command!.send(start(1, 100));
    }();
    await expectLater(
      transport.command(0x1009, sink: sink, maxDataBytes: 8),
      throwsFormatException,
    );
    expect(consumer.bytes, 0);
    await sink.close();
    await serving;
  });

  test('close interrupts blocked sink flush and queued commands', () async {
    await connect();
    final consumer = GatedConsumer();
    final sink = IOSink(consumer);
    final serving = () async {
      await camera.command!.frame();
      await camera.command!.send([
        ...start(1, 131072),
        ...data(1, List.filled(65536, 0)),
      ]);
    }();
    final first = expectLater(
      transport.command(0x1009, sink: sink),
      throwsStateError,
    );
    final second = expectLater(transport.command(0x1001), throwsStateError);
    await consumer.started.future;
    await transport.close();
    await Future.wait([first, second])
        .timeout(const Duration(milliseconds: 250));
    consumer.gate.complete();
    await consumer.drained.future;
    // Let the already-running IOSink.flush release its stream binding.
    await Future<void>.delayed(Duration.zero);
    await sink.close();
    await serving;
  });

  test(
    'a poisoned connection can only recover through an explicit new handshake',
    () async {
      await connect();
      final serving = () async {
        await camera.command!.frame();
        await camera.command!.send(response(999));
      }();
      final first = expectLater(
        transport.command(0x1001),
        throwsFormatException,
      );
      final second = expectLater(transport.command(0x1001), throwsA(anything));
      await Future.wait([first, second, serving]);
      await camera.close();
      camera = await Camera.create();
      await connect();
      final good = () async {
        final p = await camera.command!.frame();
        expect(at32(p, 14), 1);
        await camera.command!.send(response(1));
      }();
      expect((await transport.command(0x1001)).code, 0x2001);
      await good;
    },
  );

  test('delayed unsolicited response closes the idle connection', () async {
    await connect();
    final serving = () async {
      await camera.command!.frame();
      await camera.command!.send(response(1));
    }();
    await transport.command(0x1001);
    await serving;
    await camera.command!.send(response(1));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(transport.connected, isFalse);
    await expectLater(transport.command(0x1001), throwsStateError);
  });

  test('keepalive timeout closes an otherwise idle connection', () async {
    transport = PtpIpTransport(
      timeout: const Duration(milliseconds: 80),
      keepAliveInterval: const Duration(milliseconds: 20),
    );
    await connect();
    expect(await camera.event!.frame(), packet(13, []));
    await Future<void>.delayed(const Duration(milliseconds: 110));
    expect(transport.connected, isFalse);
  });

  test(
    'partial event header times out and cancels an active command',
    () async {
      transport = PtpIpTransport(
        timeout: const Duration(milliseconds: 80),
        keepAliveInterval: null,
      );
      await connect();
      await camera.event!.send([8]);
      await Future<void>.delayed(const Duration(milliseconds: 110));
      expect(transport.connected, isFalse);
    },
  );

  test('disconnect mid-packet releases active and queued commands', () async {
    await connect();
    final serving = () async {
      await camera.command!.frame();
      await camera.command!.send([
        ...start(1, 99),
        ...u32(111),
        ...u32(12),
        ...u32(1),
        9,
      ]);
      camera.command!.socket.destroy();
    }();
    final first = expectLater(transport.command(0x1009), throwsA(anything));
    final queued = expectLater(transport.command(0x1001), throwsA(anything));
    await Future.wait([first, queued, serving]);
    expect(transport.connected, isFalse);
  });

  test('timeout closes both channels and rejects queued command', () async {
    await transport.close();
    transport = PtpIpTransport(
      timeout: const Duration(milliseconds: 80),
      keepAliveInterval: null,
    );
    await connect();
    await Future.wait([
      expectLater(transport.command(0x1001), throwsA(isA<TimeoutException>())),
      expectLater(transport.command(0x1001), throwsA(anything)),
    ]);
    expect(transport.connected, isFalse);
  });

  test('close releases active and queue without waiting for timeout', () async {
    await connect();
    final first = expectLater(transport.command(0x1001), throwsA(anything));
    final second = expectLater(transport.command(0x1001), throwsA(anything));
    await camera.command!.frame();
    await transport.close();
    await Future.wait([first, second])
        .timeout(const Duration(milliseconds: 250));
    expect(transport.connected, isFalse);
  });

  test('event probe replies, unknown events are ignored and active keepalive works', () async {
    await transport.close();
    transport = PtpIpTransport(
      timeout: const Duration(seconds: 1),
      keepAliveInterval: const Duration(milliseconds: 40),
    );
    await connect();
    await camera.event!.send([
      ...packet(8, [...u16(0x4999), ...u32(0)]),
      ...packet(99, [1, 2]),
      ...packet(13, []),
    ]);
    expect(await camera.event!.frame(), packet(14, []));
    expect(await camera.event!.frame(), packet(13, []));
    await camera.event!.send(packet(14, []));
    expect(transport.connected, isTrue);
  });

  test(
    'event oversized packet breaks connection even with no active command',
    () async {
      await connect();
      await camera.event!.send([...u32(0xffffffff), ...u32(99)]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(transport.connected, isFalse);
    },
  );
}

class SlowConsumer implements StreamConsumer<List<int>> {
  int bytes = 0;
  int largest = 0;
  bool valid = true;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      largest = chunk.length > largest ? chunk.length : largest;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] != (bytes + i) % 251) valid = false;
      }
      bytes += chunk.length;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  @override
  Future<void> close() async {}
}

class GatedConsumer implements StreamConsumer<List<int>> {
  final started = Completer<void>();
  final gate = Completer<void>();
  final drained = Completer<void>();
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final _ in stream) {
      if (!started.isCompleted) started.complete();
      await gate.future;
    }
    drained.complete();
  }

  @override
  Future<void> close() async {}
}
