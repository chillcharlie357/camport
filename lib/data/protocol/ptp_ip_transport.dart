import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ptp_codec.dart';

class PtpResponse {
  PtpResponse(this.code, List<int> parameters, this.data, this.receivedBytes)
    : parameters = List<int>.unmodifiable(parameters);

  final int code;
  final List<int> parameters;

  /// Empty when a caller-owned sink received the data.
  final Uint8List data;
  final int receivedBytes;
}

/// PTP/IP command + event channels. Supports no-data/data-in operations only.
///
/// GUID bytes are caller supplied wire-order and are copied without reordering.
/// For IEM compatibility the caller serializes each UUID 64-bit half LE.
/// `maxDataBytes` limits the complete data phase even with a sink. The caller
/// must opt into an appropriate object-size limit for original-image downloads.
/// A sink is flushed with backpressure but never closed by this transport.
/// `timeout` bounds each wait for I/O progress (including sink flush), not the
/// total duration of a progressing download. `keepAliveInterval: null` disables
/// active probes; incoming event-channel probes are still answered.
/// Any I/O, timeout or framing error poisons both channels. Explicit connect()
/// creates a fresh connection; queued commands never migrate to that connection.
class PtpIpTransport {
  PtpIpTransport({
    this.timeout = const Duration(seconds: 15),
    this.keepAliveInterval = const Duration(seconds: 10),
    this.maxPacketBytes = 64 * 1024 * 1024,
  }) {
    if (timeout <= Duration.zero ||
        (keepAliveInterval != null && keepAliveInterval! <= Duration.zero) ||
        maxPacketBytes < 8 ||
        maxPacketBytes > 0xffffffff) {
      throw ArgumentError('Invalid PTP/IP limits');
    }
  }

  final Duration timeout;
  final Duration? keepAliveInterval;
  final int maxPacketBytes;
  _Link? _link;
  bool get connected => _link?.initialized == true && !_link!.closed;

  Future<void> connect({
    required String host,
    required int port,
    required Uint8List guid,
    String friendlyName = 'Sony Camera Import',
  }) async {
    if (guid.length != 16) {
      throw ArgumentError('GUID must have 16 wire-order bytes');
    }
    final units = friendlyName.codeUnits;
    ptpDecodeUtf16(units);
    if (units.length > 39 || units.contains(0)) {
      throw ArgumentError('Friendly name must fit 39 UTF-16 units without NUL');
    }
    if (_link != null && !_link!.closed) {
      throw StateError('Already connecting/connected');
    }
    final c = _Link(timeout);
    _link = c;
    try {
      c.command = await _open(c, host, port);
      await c.command!.write(
        _packet(1, [
          ...guid,
          ...units.expand(ptpPackUint16),
          0,
          0,
          ...ptpPackUint32(0x10000),
        ]),
      );
      final ack = await _header(c.command!);
      if (ack.type != 2 || ack.body < 26 || ack.body > 104 || ack.body.isOdd) {
        throw const FormatException('Invalid InitCommandAck');
      }
      final bytes = await c.command!.read(ack.body);
      final reader = PtpReader(bytes);
      final connectionId = reader.uint32();
      // 16-byte responder GUID is opaque. Friendly name is NUL-terminated,
      // unlike a length-prefixed PTP dataset string.
      final view = ByteData.sublistView(bytes);
      final remoteUnits = <int>[];
      for (var p = 20; p < bytes.length - 4; p += 2) {
        remoteUnits.add(view.getUint16(p, Endian.little));
      }
      if (remoteUnits.isEmpty ||
          remoteUnits.removeLast() != 0 ||
          remoteUnits.contains(0)) {
        throw const FormatException('Invalid responder name');
      }
      ptpDecodeUtf16(remoteUnits);
      if (view.getUint32(bytes.length - 4, Endian.little) != 0x10000) {
        throw const FormatException('Unsupported PTP/IP version');
      }
      c.event = await _open(c, host, port);
      await c.event!.write(_packet(3, ptpPackUint32(connectionId)));
      final eventAck = await _header(c.event!);
      if (eventAck.type != 4 || eventAck.body != 0) {
        throw const FormatException('Invalid InitEventAck');
      }
      c.command!.idle = true;
      if (c.command!.available > 0) {
        throw const FormatException('Unsolicited command packet');
      }
      c.initialized = true;
      unawaited(_events(c));
      final interval = keepAliveInterval;
      if (interval != null) {
        c.keepAlive = Timer.periodic(interval, (_) => unawaited(_probe(c)));
      }
    } catch (error, stack) {
      c.fail(error, stack);
      rethrow;
    }
  }

  Future<_Wire> _open(_Link c, String host, int port) async {
    final opening = RawSocket.connect(host, port, timeout: timeout);
    // A close during connect must also destroy a socket that finishes later.
    unawaited(
      opening.then((socket) {
        if (c.closed) socket.close();
      }, onError: (Object _, StackTrace _) {}),
    );
    return _Wire(await c.wait(opening), c);
  }

  Future<PtpResponse> command(
    int operation, {
    List<int> parameters = const [],
    int maxDataBytes = 1024 * 1024,
    IOSink? sink,
    int? transactionId,
  }) async {
    RangeError.checkValueInInterval(operation, 0, 0xffff);
    if (parameters.length > 5 || maxDataBytes < 0) {
      throw ArgumentError('Invalid command limits');
    }
    final params = List<int>.of(parameters);
    for (final p in params) {
      RangeError.checkValueInInterval(p, 0, 0xffffffff);
    }
    if (transactionId != null) {
      RangeError.checkValueInInterval(transactionId, 0, 0xffffffff);
    }
    final c = _link;
    if (c == null || !connected) throw StateError('PTP/IP is not connected');
    final previous = c.tail;
    final release = Completer<void>();
    c.tail = release.future;
    try {
      // Queue waits have no independent timeout. The active operation owns its
      // I/O deadline, and close/failure releases every waiter immediately.
      await c.wait(previous, timed: false);
      c.check();
      final wire = c.command!;
      if (wire.available > 0) {
        throw const FormatException('Unsolicited command packet');
      }
      wire.idle = false;
      final tid = transactionId ?? c.nextTransactionId++;
      if (tid > 0xffffffff) {
        throw StateError('Transaction IDs exhausted; reconnect');
      }
      await wire.write(
        _packet(6, [
          ...ptpPackUint32(1), // NoDataOrDataInPhase; 2 would be data-out.
          ...ptpPackUint16(operation), ...ptpPackUint32(tid),
          ...params.expand(ptpPackUint32),
        ]),
      );
      var started = false;
      var ended = false;
      var total = 0;
      var received = 0;
      final memory = sink == null ? BytesBuilder(copy: false) : null;
      while (true) {
        final h = await _header(wire);
        if (h.type == 9) {
          if (started || h.body != 12) {
            throw const FormatException('Invalid StartData');
          }
          final r = PtpReader(await wire.read(12));
          _tid(r.uint32(), tid);
          total = r.uint64();
          if (total > maxDataBytes) {
            throw const FormatException('Data exceeds maxDataBytes');
          }
          started = true;
        } else if (h.type == 10 || h.type == 12) {
          if (!started || ended || h.body < 4) {
            throw const FormatException('Invalid data phase');
          }
          _tid(PtpReader(await wire.read(4)).uint32(), tid);
          var remaining = h.body - 4;
          if (remaining > total - received ||
              remaining > maxDataBytes - received) {
            throw const FormatException('Data exceeds announced size');
          }
          while (remaining > 0) {
            final chunk = await wire.read(math.min(remaining, _Wire.blockSize));
            if (sink != null) {
              sink.add(chunk);
              await c.wait(sink.flush());
            } else {
              memory!.add(chunk);
            }
            remaining -= chunk.length;
            received += chunk.length;
          }
          if (h.type == 12) {
            if (received != total) {
              throw const FormatException('Incomplete data phase');
            }
            ended = true;
          }
        } else if (h.type == 7) {
          if (h.body < 6 ||
              h.body > 26 ||
              (h.body - 6) % 4 != 0 ||
              (started && !ended)) {
            throw const FormatException('Invalid OperationResponse');
          }
          final r = PtpReader(await wire.read(h.body));
          final code = r.uint16();
          _tid(r.uint32(), tid);
          final responseParams = <int>[];
          while (r.remaining > 0) {
            responseParams.add(r.uint32());
          }
          // A second response already on the wire cannot be attributed to the
          // next request. Idle monitoring catches delayed unsolicited packets.
          if (wire.available > 0) {
            throw const FormatException('Multiple command responses');
          }
          wire.idle = true;
          return PtpResponse(
            code,
            responseParams,
            memory?.takeBytes() ?? Uint8List(0),
            received,
          );
        } else {
          throw FormatException('Unexpected command packet ${h.type}');
        }
      }
    } catch (error, stack) {
      c.fail(error, stack);
      rethrow;
    } finally {
      release.complete();
    }
  }

  Future<_Header> _header(
    _Wire wire, {
    bool idleWait = false,
    int? limit,
  }) async {
    final bytes = idleWait
        ? Uint8List.fromList([
            ...await wire.read(1, timed: false),
            ...await wire.read(7),
          ])
        : await wire.read(8);
    final r = PtpReader(bytes);
    final length = r.uint32();
    final type = r.uint32();
    if (length < 8 || length > (limit ?? maxPacketBytes)) {
      throw const FormatException('PTP/IP packet length out of bounds');
    }
    return _Header(type, length - 8);
  }

  Future<void> _events(_Link c) async {
    try {
      while (!c.closed) {
        final h = await _header(
          c.event!,
          idleWait: true,
          limit: math.min(maxPacketBytes, 65536),
        );
        if (h.type == 13 || h.type == 14) {
          if (h.body != 0) throw const FormatException('Invalid probe packet');
          if (h.type == 13) {
            await c.sendEvent(_packet(14, []));
          } else {
            c.probeDeadline?.cancel();
            c.probeDeadline = null;
          }
        } else {
          // Unknown vendor event packets are ignored, but lengths are checked
          // before allocating, and bodies are drained in bounded chunks.
          if (h.type == 8 &&
              (h.body < 6 || h.body > 18 || (h.body - 6) % 4 != 0)) {
            throw const FormatException('Invalid Event packet');
          }
          var remaining = h.body;
          while (remaining > 0) {
            final chunk = await c.event!.read(
              math.min(remaining, _Wire.blockSize),
            );
            remaining -= chunk.length;
          }
        }
      }
    } catch (error, stack) {
      c.fail(error, stack);
    }
  }

  Future<void> _probe(_Link c) async {
    if (c.closed || c.probeDeadline != null) return;
    try {
      c.probeDeadline = Timer(
        timeout,
        () => c.fail(
          TimeoutException('PTP/IP probe timed out', timeout),
          StackTrace.current,
        ),
      );
      await c.sendEvent(_packet(13, []));
    } catch (error, stack) {
      c.fail(error, stack);
    }
  }

  Future<void> close() async {
    _link?.fail(StateError('PTP/IP closed'), StackTrace.current);
  }
}

void _tid(int actual, int expected) {
  if (actual != expected) {
    throw FormatException('Transaction mismatch: $actual != $expected');
  }
}

Uint8List _packet(int type, List<int> body) => Uint8List.fromList([
  ...ptpPackUint32(body.length + 8),
  ...ptpPackUint32(type),
  ...body,
]);

class _Header {
  _Header(this.type, this.body);
  final int type;
  final int body;
}

class _Link {
  _Link(this.timeout);
  final Duration timeout;
  _Wire? command;
  _Wire? event;
  bool initialized = false;
  bool closed = false;
  Object? failure;
  StackTrace? failureStack;
  // Remove cancellation hooks after each read/flush; attaching then() to one
  // never-ending close future would retain one closure per streamed chunk.
  final Set<void Function()> _cancelWaiters = {};
  Future<void> tail = Future<void>.value();
  Future<void> eventTail = Future<void>.value();
  int nextTransactionId = 1;
  Timer? keepAlive;
  Timer? probeDeadline;

  void check() {
    if (closed) Error.throwWithStackTrace(failure!, failureStack!);
  }

  Future<T> wait<T>(Future<T> work, {bool timed = true}) {
    final result = Completer<T>();
    Timer? deadline;
    late void Function() cancel;
    void finish({T? value, Object? error, StackTrace? stack}) {
      if (result.isCompleted) return;
      deadline?.cancel();
      _cancelWaiters.remove(cancel);
      if (error != null) {
        result.completeError(error, stack);
      } else {
        result.complete(value);
      }
    }

    cancel = () => finish(error: failure!, stack: failureStack!);
    // Always consume late completion/errors of work, including after close.
    work.then(
      (value) => finish(value: value),
      onError: (Object error, StackTrace stack) {
        finish(error: error, stack: stack);
      },
    );
    if (closed) {
      cancel();
    } else {
      _cancelWaiters.add(cancel);
      if (timed) {
        deadline = Timer(
          timeout,
          () => finish(
            error: TimeoutException('PTP/IP I/O timed out', timeout),
            stack: StackTrace.current,
          ),
        );
      }
    }
    return result.future;
  }

  Future<void> sendEvent(Uint8List bytes) async {
    final previous = eventTail;
    final release = Completer<void>();
    eventTail = release.future;
    try {
      await wait(previous);
      check();
      await event!.write(bytes);
    } finally {
      release.complete();
    }
  }

  void fail(Object error, StackTrace stack) {
    if (closed) return;
    failure = error;
    failureStack = stack;
    closed = true;
    initialized = false;
    keepAlive?.cancel();
    probeDeadline?.cancel();
    for (final cancel in _cancelWaiters.toList(growable: false)) {
      cancel();
    }
    command?.dispose();
    event?.dispose();
  }
}

/// Pulls from the OS socket into buffers of at most 64 KiB. RawSocket avoids
/// the unbounded paused-subscription queue of a buffered Socket stream.
class _Wire {
  _Wire(this.socket, this.link) {
    socket.writeEventsEnabled = false;
    socket.readEventsEnabled = false;
    subscription = socket.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          socket.readEventsEnabled = false;
          if (idle) {
            link.fail(
              const FormatException('Unsolicited command bytes'),
              StackTrace.current,
            );
          } else {
            _readReady?.complete();
            _readReady = null;
          }
        } else if (event == RawSocketEvent.write) {
          socket.writeEventsEnabled = false;
          _writeReady?.complete();
          _writeReady = null;
        } else if (event == RawSocketEvent.readClosed ||
            event == RawSocketEvent.closed) {
          ended = true;
          _readReady?.complete();
          _readReady = null;
          if (idle) {
            link.fail(
              const SocketException('PTP/IP peer disconnected'),
              StackTrace.current,
            );
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        link.fail(error, stack);
      },
    );
  }
  static const blockSize = 65536;
  final RawSocket socket;
  final _Link link;
  late final StreamSubscription<RawSocketEvent> subscription;
  Completer<void>? _readReady;
  Completer<void>? _writeReady;
  bool ended = false;
  bool _idle = false;
  int get available => socket.available();
  set idle(bool value) {
    _idle = value;
    socket.readEventsEnabled = value;
  }

  bool get idle => _idle;

  Future<Uint8List> read(int count, {bool timed = true}) async {
    if (count > blockSize || count < 0) {
      throw ArgumentError('Read exceeds buffer limit');
    }
    link.check();
    final bytes = Uint8List(count);
    var offset = 0;
    while (offset < count) {
      link.check();
      final part = socket.read(count - offset);
      if (part != null && part.isNotEmpty) {
        bytes.setRange(offset, offset + part.length, part);
        offset += part.length;
      } else {
        if (ended) throw const SocketException('Truncated PTP/IP stream');
        final ready = Completer<void>();
        _readReady = ready;
        socket.readEventsEnabled = true;
        await link.wait(ready.future, timed: timed);
      }
    }
    return bytes;
  }

  Future<void> write(Uint8List bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      link.check();
      final n = socket.write(bytes, offset);
      if (n > 0) {
        offset += n;
      } else {
        final ready = Completer<void>();
        _writeReady = ready;
        socket.writeEventsEnabled = true;
        await link.wait(ready.future);
      }
    }
  }

  void dispose() {
    socket.close();
    unawaited(subscription.cancel());
  }
}
