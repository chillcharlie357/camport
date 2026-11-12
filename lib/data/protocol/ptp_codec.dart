import 'dart:typed_data';

/// Bounded little-endian reader for PTP datasets (not PTP/IP packet framing).
class PtpReader {
  PtpReader(Uint8List bytes, {this.maxArrayElements = 1024 * 1024})
    : _bytes = bytes,
      _view = ByteData.sublistView(bytes) {
    if (maxArrayElements < 0) throw ArgumentError.value(maxArrayElements);
  }

  final Uint8List _bytes;
  final ByteData _view;
  final int maxArrayElements;
  int _offset = 0;
  int get remaining => _bytes.length - _offset;

  void _need(int size) {
    if (size < 0 || size > remaining) {
      throw const FormatException('Truncated PTP dataset');
    }
  }

  int uint8() {
    _need(1);
    return _bytes[_offset++];
  }

  int uint16() {
    _need(2);
    final result = _view.getUint16(_offset, Endian.little);
    _offset += 2;
    return result;
  }

  int uint32() {
    _need(4);
    final result = _view.getUint32(_offset, Endian.little);
    _offset += 4;
    return result;
  }

  /// Dart VM integers are signed 64-bit. Reject unrepresentable unsigned sizes.
  int uint64() {
    _need(8);
    if (_view.getUint32(_offset + 4, Endian.little) > 0x7fffffff) {
      throw const FormatException('PTP uint64 exceeds signed integer range');
    }
    final result = _view.getUint64(_offset, Endian.little);
    _offset += 8;
    return result;
  }

  String ptpString() {
    final count = uint8();
    if (count == 0) return '';
    _need(count * 2);
    final units = List<int>.generate(count, (_) => uint16());
    if (units.removeLast() != 0) {
      throw const FormatException('PTP string has no terminator');
    }
    return ptpDecodeUtf16(units);
  }

  List<int> arrays16() => _array(2, uint16);
  List<int> arrays32() => _array(4, uint32);

  List<int> _array(int width, int Function() read) {
    final count = uint32();
    if (count > maxArrayElements || count > remaining ~/ width) {
      throw const FormatException('PTP array count exceeds bounds');
    }
    return List<int>.generate(count, (_) => read(), growable: false);
  }
}

/// Strict UTF-16 decoding shared by PTP strings and handshake friendly names.
String ptpDecodeUtf16(List<int> units) {
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
        throw const FormatException('Unpaired UTF-16 high surrogate');
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw const FormatException('Unpaired UTF-16 low surrogate');
    }
  }
  return String.fromCharCodes(units);
}

Uint8List ptpPackUint16(int value) {
  RangeError.checkValueInInterval(value, 0, 0xffff);
  return (ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List();
}

Uint8List ptpPackUint32(int value) {
  RangeError.checkValueInInterval(value, 0, 0xffffffff);
  return (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();
}

Uint8List ptpPackUint64(int value) {
  if (value < 0) throw RangeError.value(value);
  return (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List();
}

Uint8List ptpPackString(String value) {
  if (value.isEmpty) return Uint8List.fromList([0]);
  final units = value.codeUnits;
  ptpDecodeUtf16(units);
  if (units.length > 254 || units.contains(0)) {
    throw ArgumentError('PTP string exceeds 254 UTF-16 units or contains NUL');
  }
  return Uint8List.fromList([
    units.length + 1,
    ...units.expand(ptpPackUint16),
    0,
    0,
  ]);
}
