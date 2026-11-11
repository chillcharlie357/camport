import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

import '../../domain/models/camera_capabilities.dart';
import '../../domain/models/camera_file.dart';
import '../../domain/models/camera_page.dart';
import '../../domain/models/camera_profile.dart';
import '../../domain/models/transfer_progress.dart';
import '../../domain/ports/camera_session.dart';
import '../protocol/ptp_codec.dart';
import '../protocol/ptp_ip_transport.dart';

const _ok = 0x2001;
const _chunkBytes = 1024 * 1024;
// Sony's contents-transfer (Smartphone Connect) download is a vendor opcode
// that differs from the standard PTP GetPartialObject. Creators' App and the
// ZV-E10 use SDIO_GetPartialLargeObject (0x9219); older Imaging Edge Mobile
// builds advertised the same role as 0x9211. Support both, preferring the
// opcode the camera actually reports.
const _ocGetPartialLargeObject = 0x9219;
const _ocLegacyGetPartialObject = 0x9211;
const _pcRemote =
    '相机没有提供存储卡内容传输。请关闭 PC Remote（电脑遥控），在相机上使用 Smartphone Connect（智能手机连接）后重试。';

/// Read-only Sony contents/PTP adapter. No capture, delete, device-log or
/// short-video/transcoding operations are sent. Original destinations must be
/// caller-owned .part files; final rename/hash verification belongs to the queue.
class SonyPtpCameraAdapter implements CameraSession {
  SonyPtpCameraAdapter({
    required Uint8List guid,
    PtpIpTransport? transport,
    this.pageSize = 20,
  }) : _guid = Uint8List.fromList(guid),
       // GetObject-only cameras may send an entire large original in one
       // PTP/IP packet. The transport still pulls at most 64 KiB at a time,
       // while each command's maxDataBytes is the fresh source file size.
       _transport = transport ?? PtpIpTransport(maxPacketBytes: 0xffffffff) {
    if (guid.length != 16 || pageSize < 1 || pageSize > 200) {
      throw ArgumentError('Invalid Sony adapter configuration');
    }
  }

  final Uint8List _guid;
  final PtpIpTransport _transport;
  final int pageSize;
  CameraProfile? _profile;
  String? _cacheNamespace;
  bool _ready = false;
  bool _connecting = false;
  int _generation = 0;
  String _epoch = '';
  int _snapshot = 0;
  final Set<int> _operations = {};
  final Map<int, _Storage> _storages = {};
  final Map<String, CameraFile> _metadata = {};
  final Map<String, _Expected> _expected = {};
  List<_ObjectRef>? _handles;
  _Download? _active;

  @override
  bool get connected => _ready && _transport.connected;
  @override
  CameraProfile? get profile => _profile;

  /// Null means identity could not be verified; never reuse a persistent cache.
  @override
  String? get cacheNamespace => _cacheNamespace;
  Set<int> get reportedOperations => Set<int>.unmodifiable(_operations);

  @override
  Future<CameraProfile> connect(CameraProfile profile) async {
    final config = profile.connectionConfiguration;
    final host = config['host'] ?? '';
    final port = int.tryParse(config['port'] ?? '15740');
    if (!_isLan(host) || port == null || port < 1 || port > 65535) {
      throw ArgumentError('请输入相机的局域网 IPv4 地址和有效端口');
    }
    if (_connecting || connected || _active != null) {
      throw StateError('相机正在连接或传输，请先关闭当前连接');
    }
    _connecting = true;
    final generation = ++_generation;
    _ready = false;
    _profile = null;
    _cacheNamespace = null;
    _storages.clear();
    _metadata.clear();
    _operations.clear();
    _handles = null;
    _epoch = _nonce();
    try {
      await _transport.connect(host: host, port: port, guid: _guid);
      _check(generation);
      final info = _DeviceInfo.parse(
        (await _call(0x1001, generation, transactionId: 0)).data,
      );
      _check(generation);
      if (!RegExp(
        r'\bsony\b',
        caseSensitive: false,
      ).hasMatch(info.manufacturer)) {
        throw UnsupportedError('此连接不是 Sony 相机');
      }
      _operations.addAll(info.operations);
      final manualZve10 =
          profile.id.startsWith('manual:') &&
          (profile.model ?? info.model).toUpperCase().replaceAll(
                RegExp('[^A-Z0-9]'),
                '',
              ) ==
              'ZVE10';
      final wantsContents =
          _operations.contains(0x9210) ||
          _operations.contains(0x9212) ||
          config['mediaServer'] == 'true' ||
          manualZve10;
      var sonySession = false;
      var contentsEnabled = false;
      if (wantsContents) {
        try {
          await _call(0x9210, generation, parameters: [1, 1], transactionId: 0);
          sonySession = true;
        } on SonyPtpResponseException catch (e) {
          if (e.code != 0x2005) rethrow;
        }
      }
      if (!sonySession) {
        if (!_operations.contains(0x1002)) throw UnsupportedError(_pcRemote);
        await _call(0x1002, generation, parameters: [1], transactionId: 0);
      }
      if (wantsContents ||
          (_operations.contains(0x9201) && _operations.contains(0x9202))) {
        try {
          await _call(0x9201, generation, parameters: [1, 0, 0]);
          await _call(0x9201, generation, parameters: [2, 0, 0]);
          final ext = PtpReader(
            (await _call(0x9202, generation, parameters: [300])).data,
          );
          ext.uint16();
          ext.arrays16();
          ext.arrays16();
          if (ext.remaining != 0) {
            throw const FormatException('Invalid Sony extended device info');
          }
          // Extended arrays contain property/control codes, not operations.
          await _call(0x9201, generation, parameters: [3, 0, 0]);
          await _call(0x9212, generation, parameters: [2, 1, 0]);
          contentsEnabled = true;
        } on SonyPtpResponseException catch (e) {
          throw UnsupportedError('$_pcRemote（${e.code.toRadixString(16)}）');
        }
      }
      if (![0x1004, 0x1005, 0x1007, 0x1008].every(_operations.contains)) {
        throw UnsupportedError(_pcRemote);
      }
      final storageReader = PtpReader(
        (await _call(0x1004, generation)).data,
        maxArrayElements: 256,
      );
      final ids = storageReader.arrays32();
      if (storageReader.remaining != 0 || ids.isEmpty) {
        throw UnsupportedError(_pcRemote);
      }
      for (final id in ids) {
        if (id == 0 || id == 0xffffffff || _storages.containsKey(id)) {
          throw const FormatException('Invalid storage ID');
        }
        await _refreshStorage(id, generation);
      }
      final identity = _identity(info, profile);
      _check(generation);
      final id = identity ?? 'sony:unverified:${_nonce()}';
      _cacheNamespace = identity == null ? null : 'sony-ptp-v1:$id';
      _profile = CameraProfile(
        id: id,
        displayName: info.model.isEmpty ? 'Sony 相机' : info.model,
        model: info.model,
        firmware: info.firmware,
        connectionKind: profile.connectionKind,
        connectionConfiguration: {
          ...config,
          'adapter': 'sony-ptp',
          'host': host,
          'port': '$port',
          if (contentsEnabled) 'mediaServer': 'true',
          if (_udn(profile) != null) 'udn': _udn(profile)!,
          'identityVerified': '${identity != null}',
        },
      );
      _check(generation);
      _ready = true;
      return _profile!;
    } catch (error) {
      if (_generation == generation) {
        _ready = false;
        await _transport.close();
      }
      if (error is SonyPtpResponseException &&
          (error.operation == 0x1004 || error.operation == 0x1005)) {
        throw UnsupportedError('$_pcRemote（${error.code.toRadixString(16)}）');
      }
      rethrow;
    } finally {
      _connecting = false;
    }
  }

  @override
  Future<CameraCapabilities> discoverCapabilities() async {
    _requireConnected();
    return CameraCapabilities(
      canListFiles: [
        0x1004,
        0x1005,
        0x1007,
        0x1008,
      ].every(_operations.contains),
      hasThumbnails: _operations.contains(0x100a),
      canDownloadOriginals: [
        _ocGetPartialLargeObject,
        _ocLegacyGetPartialObject,
        0x101b,
        0x1009,
      ].any(_operations.contains),
      canRemoteControl: false,
      hasLiveView: false,
    );
  }

  @override
  Future<CameraPage<CameraFile>> listFiles({String? cursor}) async {
    _requireConnected();
    final generation = _generation;
    var index = 0;
    if (cursor == null) {
      final refs = <_ObjectRef>[];
      for (final id in _storages.keys.toList()) {
        final r = PtpReader(
          (await _call(0x1007, generation, parameters: [id, 0, 0])).data,
          maxArrayElements: 200000,
        );
        final handles = r.arrays32();
        if (r.remaining != 0 || handles.toSet().length != handles.length) {
          throw const FormatException('Invalid object handle list');
        }
        for (final handle in handles) {
          if (handle == 0 || handle == 0xffffffff) {
            throw const FormatException('Invalid object handle');
          }
          refs.add(_ObjectRef(id, handle));
        }
        if (refs.length > 200000) {
          throw const FormatException('Too many camera objects');
        }
      }
      _check(generation);
      _handles = refs;
      _snapshot++;
    } else {
      final parts = cursor.split(':');
      if (parts.length != 3 ||
          parts[0] != _epoch ||
          parts[1] != '$_snapshot' ||
          _handles == null) {
        throw StateError('图库分页已过期，请重新加载');
      }
      final parsed = int.tryParse(parts[2]);
      if (parsed == null || parsed < 0 || parsed >= _handles!.length) {
        throw const FormatException('Invalid page cursor');
      }
      index = parsed;
    }
    final refs = _handles!;
    final items = <CameraFile>[];
    final refreshed = <int>{};
    while (index < refs.length && items.length < pageSize) {
      final ref = refs[index++];
      if (refreshed.add(ref.storage)) {
        await _refreshStorage(ref.storage, generation);
      }
      final meta = await _describe(ref, generation);
      _check(generation);
      if (!meta.association) {
        items.add(meta.file);
        _metadata[meta.file.id] = meta.file;
      }
    }
    _check(generation);
    return CameraPage(
      items: items,
      nextCursor: index < refs.length ? '$_epoch:$_snapshot:$index' : null,
    );
  }

  @override
  Future<CameraFile> describeFile(String fileId) async {
    _requireConnected();
    final generation = _generation;
    final ref = _ref(fileId);
    await _refreshStorage(ref.storage, generation);
    final meta = await _describe(ref, generation);
    _check(generation);
    if (meta.association) throw UnsupportedError('该对象是目录，不能作为文件导入');
    _metadata[fileId] = meta.file;
    return meta.file;
  }

  /// Queue-provided source identity. Checked against fresh metadata before any
  /// part-file write, including resumed and already-complete temporary files.
  @override
  void expectFile(String fileId, {String? sourceVersion, int? byteLength}) {
    _ref(fileId);
    if (byteLength != null && byteLength < 0) {
      throw ArgumentError.value(byteLength);
    }
    _expected[fileId] = _Expected(sourceVersion, byteLength);
  }

  Future<_ObjectMeta> _describe(_ObjectRef ref, int generation) async {
    final bytes = (await _call(
      0x1008,
      generation,
      parameters: [ref.handle],
    )).data;
    final r = PtpReader(bytes);
    final storage = r.uint32();
    final format = r.uint16();
    r.uint16();
    var size = r.uint32();
    r.uint16(); // thumbnail format
    for (var i = 0; i < 6; i++) {
      r.uint32();
    }
    final parent = r.uint32();
    final association = r.uint16();
    r.uint32();
    r.uint32();
    final name = r.ptpString();
    final captured = r.ptpString();
    r.ptpString();
    r.ptpString();
    if (r.remaining != 0 ||
        storage != ref.storage ||
        name.isEmpty ||
        name.contains(RegExp(r'[/\\\x00]'))) {
      throw const FormatException('Invalid ObjectInfo');
    }
    if (size == 0xffffffff) {
      if (!_operations.contains(0x9803)) {
        throw UnsupportedError('相机没有提供可验证的大文件大小，无法安全导入');
      }
      final sizeReader = PtpReader(
        (await _call(
          0x9803,
          generation,
          parameters: [ref.handle, 0xdc04],
          maxDataBytes: 8,
        )).data,
      );
      size = sizeReader.uint64();
      if (sizeReader.remaining != 0) {
        throw const FormatException('Invalid ObjectSize');
      }
    }
    _check(generation);
    final revision = _hash([
      utf8.encode(_profile!.id),
      _storages[storage]!.fingerprint,
      bytes,
      ptpPackUint64(size),
    ]);
    final dot = name.lastIndexOf('.');
    final file = CameraFile(
      id: ref.id,
      name: name,
      extension: dot < 0 ? '' : name.substring(dot + 1).toUpperCase(),
      format: CameraFileFormat.fromFileName(name),
      byteLength: size,
      capturedAt: _date(captured),
      thumbnailKey: 'ptp-v1:$revision',
      directory: '${_profile!.id}/${_hex(storage)}/${_hex(parent)}',
    );
    return _ObjectMeta(file, format == 0x3001 || association != 0);
  }

  Future<void> _refreshStorage(int id, int generation) async {
    final r = PtpReader(
      (await _call(0x1005, generation, parameters: [id])).data,
    );
    final type = r.uint16();
    final fileSystem = r.uint16();
    final access = r.uint16();
    // Capacity stays an exact pair of words, including PTP's unknown sentinel.
    // FreeSpace may also be UINT64_MAX, so skip its words without signed casts.
    final capacityLow = r.uint32();
    final capacityHigh = r.uint32();
    r.uint32();
    r.uint32();
    r.uint32(); // free bytes/images are deliberately excluded
    final description = r.ptpString();
    final label = r.ptpString();
    if (r.remaining != 0) throw const FormatException('Invalid StorageInfo');
    _check(generation);
    _storages[id] = _Storage(
      utf8.encode(
        jsonEncode([
          id,
          type,
          fileSystem,
          access,
          capacityLow,
          capacityHigh,
          description,
          label,
        ]),
      ),
    );
  }

  @override
  Future<Uint8List?> loadThumbnail(String fileId) async {
    _requireConnected();
    final generation = _generation;
    final ref = _ref(fileId);
    if (!_operations.contains(0x100a)) return null;
    try {
      final response = await _call(
        0x100a,
        generation,
        parameters: [ref.handle],
        maxDataBytes: 2 * 1024 * 1024,
      );
      // Only GetThumb bytes reach image decoders. Never decode original RAW.
      final bytes = response.data;
      final dimensions = _previewHeader(bytes);
      if (dimensions == null) return null;
      final result = await Isolate.run(() => _resizePreview(bytes, dimensions));
      _check(generation);
      return result;
    } on SonyPtpResponseException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Stream<TransferProgress> downloadOriginal(
    String fileId,
    String destinationPath,
  ) {
    late StreamController<TransferProgress> controller;
    _Download? token;
    controller = StreamController<TransferProgress>(
      onListen: () {
        if (!connected || _active != null) {
          controller.addError(StateError('相机未连接或正在传输其他文件'));
          unawaited(controller.close());
          return;
        }
        token = _Download(_generation);
        _active = token;
        unawaited(_download(fileId, destinationPath, token!, controller));
      },
      onCancel: () async {
        final current = token;
        if (current == null || current.finished) return;
        current.cancelled = true;
        if (_generation == current.generation) await close();
        await current.done.future;
      },
    );
    return controller.stream;
  }

  Future<void> _download(
    String id,
    String path,
    _Download token,
    StreamController<TransferProgress> output,
  ) async {
    RandomAccessFile? file;
    var committed = 0;
    var mayRollback = false;
    try {
      final cached = _metadata[id];
      final expected =
          _expected[id] ?? _Expected(cached?.thumbnailKey, cached?.byteLength);
      final meta = await describeFile(id);
      _checkDownload(token);
      if ((expected.version != null && expected.version != meta.thumbnailKey) ||
          (expected.length != null && expected.length != meta.byteLength)) {
        throw StateError('相机中的源文件已变化，请重新加入导入队列');
      }
      if (!path.endsWith('.part')) throw ArgumentError('原片只能写入临时 .part 文件');
      final destination = File(path);
      final type = await FileSystemEntity.type(path, followLinks: false);
      _checkDownload(token);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw FileSystemException('临时文件不能是符号链接或目录', path);
      }
      file = await destination.open(mode: FileMode.append);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw FileSystemException('临时文件类型已变化', path);
      }
      committed = await file.length();
      _checkDownload(token);
      if (committed > meta.byteLength) {
        throw StateError('临时文件长度超过源文件，请重新创建导入任务');
      }
      var operation = _downloadOperation(meta.byteLength, committed);
      if (operation == 0x1009 &&
          committed != 0 &&
          committed < meta.byteLength) {
        await file.truncate(0);
        committed = 0;
      }
      mayRollback = true;
      final ref = _ref(id);
      var emitted = false;
      while (committed < meta.byteLength) {
        _checkDownload(token);
        await file.setPosition(committed);
        _checkDownload(token);
        final count = operation == 0x1009
            ? meta.byteLength
            : math.min(_chunkBytes, meta.byteLength - committed);
        final params = operation == _ocGetPartialLargeObject ||
                operation == _ocLegacyGetPartialObject
            ? [
                ref.handle,
                committed & 0xffffffff,
                committed ~/ 0x100000000,
                count,
              ]
            : operation == 0x101b
            ? [ref.handle, committed, count]
            : [ref.handle];
        final consumer = _PartConsumer(file, token, count);
        final sink = IOSink(consumer);
        // IOSink.done may report an error separately from flush(). Consume it.
        unawaited(
          sink.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
        SonyPtpResponseException? unsupported;
        try {
          final response = await _call(
            operation,
            token.generation,
            parameters: params,
            maxDataBytes: count,
            sink: sink,
          );
          await sink.flush();
          _checkDownload(token);
          if (response.receivedBytes != count ||
              consumer.written != count ||
              (operation != 0x1009 &&
                  response.parameters.isNotEmpty &&
                  response.parameters.first != count)) {
            throw const FormatException('原片数据块长度与源文件不符');
          }
        } on SonyPtpResponseException catch (e) {
          if (e.code == 0x2005 && operation != 0x1009) {
            unsupported = e;
          } else {
            rethrow;
          }
        } finally {
          await consumer.settle();
          try {
            await sink.close();
          } catch (_) {
            /* the operation reports the failure */
          }
        }
        _checkDownload(token);
        if (unsupported != null) {
          await file.truncate(committed);
          _operations.remove(operation);
          operation = _downloadOperation(meta.byteLength, committed);
          if (operation == 0x1009 && committed != 0) {
            await file.truncate(0);
            committed = 0;
          }
          continue;
        }
        await file.flush();
        _checkDownload(token);
        committed += count;
        emitted = true;
        output.add(
          TransferProgress(
            bytesTransferred: committed,
            totalBytes: meta.byteLength,
          ),
        );
      }
      if (!emitted) {
        await file.flush();
        _checkDownload(token);
        output.add(
          TransferProgress(
            bytesTransferred: committed,
            totalBytes: meta.byteLength,
          ),
        );
      }
    } catch (error, stack) {
      if (file != null && mayRollback) {
        try {
          await file.truncate(committed);
          await file.flush();
        } catch (_) {
          /* preserve primary failure */
        }
      }
      if (!token.cancelled && !output.isClosed) output.addError(error, stack);
    } finally {
      if (file != null) {
        try {
          await file.close();
        } catch (_) {}
      }
      token.finished = true;
      if (identical(_active, token)) _active = null;
      token.done.complete();
      unawaited(output.close());
    }
  }

  int _downloadOperation(int total, int offset) {
    if (_operations.contains(_ocGetPartialLargeObject)) {
      return _ocGetPartialLargeObject;
    }
    if (_operations.contains(_ocLegacyGetPartialObject)) {
      return _ocLegacyGetPartialObject;
    }
    if (_operations.contains(0x101b) &&
        total <= 0x100000000 &&
        offset <= 0xffffffff) {
      return 0x101b;
    }
    // PTP/IP packet length is a 32-bit field. GetObject may return the whole
    // file as a single EndData packet (header + transaction ID + payload).
    if (_operations.contains(0x1009) && total <= 0xffffffff - 12) {
      return 0x1009;
    }
    throw UnsupportedError('相机不支持此文件大小的原片传输或 64 位续传');
  }

  Future<PtpResponse> _call(
    int operation,
    int generation, {
    List<int> parameters = const [],
    int maxDataBytes = 1024 * 1024,
    IOSink? sink,
    int? transactionId,
  }) async {
    _check(generation);
    final response = await _transport.command(
      operation,
      parameters: parameters,
      maxDataBytes: maxDataBytes,
      sink: sink,
      transactionId: transactionId,
    );
    _check(generation);
    if (response.code != _ok) {
      throw SonyPtpResponseException(operation, response.code);
    }
    if (response.receivedBytes > maxDataBytes ||
        (sink == null &&
            (response.data.length > maxDataBytes ||
                response.receivedBytes != response.data.length))) {
      throw const FormatException('PTP response exceeds bounded data length');
    }
    return response;
  }

  _ObjectRef _ref(String id) {
    if (!RegExp(r'^[0-9a-fA-F]{8}:[0-9a-fA-F]{8}$').hasMatch(id)) {
      throw ArgumentError('Invalid camera file ID');
    }
    final parts = id.split(':');
    final storage = int.parse(parts[0], radix: 16);
    final handle = int.parse(parts[1], radix: 16);
    if (!_storages.containsKey(storage) ||
        handle == 0 ||
        handle == 0xffffffff) {
      throw StateError('文件不属于当前存储卡');
    }
    return _ObjectRef(storage, handle);
  }

  void _requireConnected() {
    if (!connected) throw StateError('相机未连接');
  }

  void _check(int generation) {
    if (_generation != generation) throw StateError('相机连接已取消或更换');
  }

  void _checkDownload(_Download token) {
    _check(token.generation);
    if (token.cancelled) throw StateError('原片传输已取消');
  }

  @override
  Future<void> close() async {
    ++_generation;
    _ready = false;
    _handles = null;
    _active?.cancelled = true;
    await _transport.close();
  }
}

class SonyPtpResponseException implements Exception {
  SonyPtpResponseException(this.operation, this.code);
  final int operation;
  final int code;
  @override
  String toString() =>
      '相机拒绝操作 0x${operation.toRadixString(16)}（PTP 0x${code.toRadixString(16)}）';
}

class _Expected {
  _Expected(this.version, this.length);
  final String? version;
  final int? length;
}

class _Storage {
  _Storage(this.fingerprint);
  final List<int> fingerprint;
}

class _ObjectRef {
  _ObjectRef(this.storage, this.handle);
  final int storage;
  final int handle;
  String get id => '${_hex(storage)}:${_hex(handle)}';
}

class _ObjectMeta {
  _ObjectMeta(this.file, this.association);
  final CameraFile file;
  final bool association;
}

class _Download {
  _Download(this.generation);
  final int generation;
  bool cancelled = false;
  bool finished = false;
  final done = Completer<void>();
}

/// One bounded data block written through a single already-open file handle.
/// No reopening by path between blocks, and cancellation is checked before
/// each write. In-flight disk writes finish before rollback truncates the file.
class _PartConsumer implements StreamConsumer<List<int>> {
  _PartConsumer(this.file, this.token, this.limit);
  final RandomAccessFile file;
  final _Download token;
  final int limit;
  int written = 0;
  Future<void>? _pending;
  @override
  Future<void> addStream(Stream<List<int>> stream) {
    final work = _write(stream);
    _pending = work;
    return work;
  }

  Future<void> _write(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      if (token.cancelled) throw StateError('传输已取消');
      if (bytes.length > limit - written) {
        throw const FormatException('Data block overflow');
      }
      await file.writeFrom(bytes);
      written += bytes.length;
    }
  }

  Future<void> settle() async {
    try {
      await _pending;
    } catch (_) {}
    // IOSink completes its flush binding after addStream's completion callback.
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> close() async {}
}

class _DeviceInfo {
  _DeviceInfo(
    this.operations,
    this.manufacturer,
    this.model,
    this.firmware,
    this.serial,
  );
  final List<int> operations;
  final String manufacturer, model, firmware, serial;
  factory _DeviceInfo.parse(Uint8List bytes) {
    final r = PtpReader(bytes);
    r.uint16();
    r.uint32();
    r.uint16();
    r.ptpString();
    r.uint16();
    final operations = r.arrays16();
    r.arrays16();
    r.arrays16();
    r.arrays16();
    r.arrays16();
    final result = _DeviceInfo(
      operations,
      r.ptpString().trim(),
      r.ptpString().trim(),
      r.ptpString(),
      r.ptpString().trim(),
    );
    if (r.remaining != 0) throw const FormatException('Invalid DeviceInfo');
    return result;
  }
}

bool _isLan(String host) {
  final ip = InternetAddress.tryParse(host);
  if (ip == null || ip.type != InternetAddressType.IPv4) return false;
  final b = ip.rawAddress;
  return b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168) ||
      (b[0] == 169 && b[1] == 254);
}

String? _identity(_DeviceInfo info, CameraProfile profile) {
  final serial = info.serial;
  final invalid = {
    'unknown',
    'none',
    'null',
    'n/a',
    'serialnumber',
    '1234567890',
  };
  if (info.model.isNotEmpty &&
      serial.length >= 4 &&
      serial.length <= 128 &&
      !invalid.contains(serial.toLowerCase()) &&
      !RegExp(r'^(.)\1+$').hasMatch(serial)) {
    return 'sony:${_hash([
      utf8.encode(jsonEncode(['serial', info.model, serial])),
    ])}';
  }
  final udn = _udn(profile);
  if (udn != null) {
    return 'sony:${_hash([
      utf8.encode(jsonEncode(['udn', udn, info.model])),
    ])}';
  }
  return null;
}

String? _udn(CameraProfile profile) {
  final udn = (profile.connectionConfiguration['udn'] ?? profile.id)
      .toLowerCase();
  if (RegExp(
        r'^uuid:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(udn) &&
      !udn.endsWith('00000000-0000-0000-0000-000000000000')) {
    return udn;
  }
  return null;
}

String _hash(List<List<int>> parts) =>
    sha256.convert(parts.expand((b) => b).toList()).toString();
String _hex(int value) => value.toRadixString(16).padLeft(8, '0');
String _nonce() => List.generate(
  16,
  (_) => math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
DateTime? _date(String value) {
  final match = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z)?$')
      .firstMatch(value);
  if (match == null) return null;
  final n = List.generate(6, (i) => int.parse(match.group(i + 1)!));
  if (n[1] < 1 ||
      n[1] > 12 ||
      n[2] < 1 ||
      n[2] > 31 ||
      n[3] > 23 ||
      n[4] > 59 ||
      n[5] > 59) {
    return null;
  }
  return match.group(7) == null
      ? DateTime(n[0], n[1], n[2], n[3], n[4], n[5])
      : DateTime.utc(n[0], n[1], n[2], n[3], n[4], n[5]);
}

/// Header-only checks precede image-package parsing or allocation. Only JPEG
/// and PNG previews are accepted; TIFF/ARW/RAW and animation are never decoded.
List<int>? _previewHeader(Uint8List bytes) {
  if (bytes.length > 2 * 1024 * 1024) return null;
  int width = 0, height = 0;
  if (bytes.length >= 24 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71 &&
      bytes[12] == 73 &&
      bytes[13] == 72 &&
      bytes[14] == 68 &&
      bytes[15] == 82) {
    final view = ByteData.sublistView(bytes);
    width = view.getUint32(16);
    height = view.getUint32(20);
  } else if (bytes.length >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8) {
    var pos = 2;
    while (pos + 4 <= bytes.length) {
      if (bytes[pos++] != 0xff) return null;
      while (pos < bytes.length && bytes[pos] == 0xff) {
        pos++;
      }
      if (pos + 3 > bytes.length) return null;
      final marker = bytes[pos++];
      if (marker == 0xda || marker == 0xd9) break;
      final length = bytes[pos] * 256 + bytes[pos + 1];
      if (length < 2 || pos + length > bytes.length) return null;
      if ({0xc0, 0xc1, 0xc2}.contains(marker)) {
        if (length < 8) return null;
        height = bytes[pos + 3] * 256 + bytes[pos + 4];
        width = bytes[pos + 5] * 256 + bytes[pos + 6];
        break;
      }
      pos += length;
    }
  }
  if (width < 1 ||
      height < 1 ||
      width > 8192 ||
      height > 8192 ||
      width * height > 8 * 1024 * 1024) {
    return null;
  }
  return [width, height];
}

Uint8List? _resizePreview(Uint8List bytes, List<int> dimensions) {
  try {
    const maxPixels = 8 * 1024 * 1024;
    img.Image? decoded;
    if (bytes[0] == 0xff) {
      final edge = math.max(dimensions[0], dimensions[1]);
      var scale = 1;
      while (scale < 8 && edge ~/ (scale * 2) >= 512) {
        scale *= 2;
      }
      decoded = img.JpegDecoder(
        maxPixels: maxPixels,
        scale: scale,
      ).decode(bytes);
    } else {
      final decoder = img.PngDecoder(maxPixels: maxPixels);
      if (decoder.startDecode(bytes) == null || decoder.numFrames() != 1) {
        return null;
      }
      decoded = decoder.decodeFrame(0);
    }
    if (decoded == null) return null;
    if (decoded.width > 512 || decoded.height > 512) {
      decoded = img.copyResize(
        decoded,
        width: decoded.width >= decoded.height ? 512 : null,
        height: decoded.height > decoded.width ? 512 : null,
      );
    }
    return img.encodeJpg(decoded, quality: 85);
  } catch (_) {
    return null;
  }
}
