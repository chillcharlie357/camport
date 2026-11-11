import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sony_camera/data/local/thumbnail_disk_cache.dart';

String hash(String key) => sha256.convert(utf8.encode(key)).toString();
Uint8List bytes(int value, [int length = 2000]) =>
    Uint8List.fromList(List.filled(length, value));

void main() {
  late Directory temporary;
  late Directory directory;
  late DateTime time;

  ThumbnailDiskCache create({
    int maxBytes = 32 * 1024,
    int maxEntryBytes = 4096,
    Duration maxAge = const Duration(days: 7),
    Directory? at,
  }) {
    final cache = ThumbnailDiskCache(
      directory: at ?? directory,
      maxBytes: maxBytes,
      maxEntryBytes: maxEntryBytes,
      maxAge: maxAge,
      now: () => time,
    );
    addTearDown(cache.close);
    return cache;
  }

  Future<int> diskBytes() async {
    var count = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) count += await entity.length();
    }
    return count;
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('thumbnail-disk-test-');
    directory = Directory('${temporary.path}/cache');
    time = DateTime.utc(2026, 11, 11);
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('writes owned bytes and reopens persistent entries', () async {
    final cache = create();
    final input = bytes(7);
    final writing = cache.write('camera/storage/photo/v1', input);
    input[0] = 1;
    await writing;
    expect(await cache.read('camera/storage/photo/v1'), bytes(7));
    await cache.close();
    final reopened = create();
    expect(await reopened.read('camera/storage/photo/v1'), bytes(7));
    expect(await reopened.read('absent'), isNull);
  });

  test(
    'read updates persistent LRU and all disk files fit the budget',
    () async {
      final cache = create(maxBytes: 6000);
      await cache.write('a', bytes(1));
      await cache.write('b', bytes(2));
      expect(await cache.read('a'), bytes(1));
      await cache.close();
      final reopened = create(maxBytes: 6000);
      await reopened.write('c', bytes(3));
      expect(await reopened.read('b'), isNull);
      expect(await reopened.read('a'), bytes(1));
      expect(await reopened.read('c'), bytes(3));
      expect(await diskBytes(), lessThanOrEqualTo(6000));
    },
  );

  test(
    'rejects empty and oversized replacement without losing old bytes',
    () async {
      final cache = create(maxEntryBytes: 2000);
      await cache.write('a', bytes(1));
      await cache.write('a', Uint8List(0));
      await cache.write('a', bytes(2, 2001));
      expect(await cache.read('a'), bytes(1));
      await cache.write('huge', bytes(3, 10000));
      expect(await cache.read('huge'), isNull);
    },
  );

  test('expires by write age even when repeatedly read', () async {
    final cache = create(maxAge: const Duration(hours: 2));
    await cache.write('a', bytes(1));
    time = time.add(const Duration(hours: 1));
    expect(await cache.read('a'), bytes(1));
    time = time.add(const Duration(hours: 1));
    expect(await cache.read('a'), isNull);
    expect(await File('${directory.path}/${hash('a')}').exists(), isFalse);
  });

  test(
    'missing, truncated, and same-length corrupt files are misses',
    () async {
      final cache = create();
      for (final key in ['missing', 'truncated', 'corrupt']) {
        await cache.write(key, bytes(1));
      }
      await File('${directory.path}/${hash('missing')}').delete();
      await File('${directory.path}/${hash('truncated')}').writeAsBytes([1]);
      await File('${directory.path}/${hash('corrupt')}').writeAsBytes(bytes(2));
      for (final key in ['missing', 'truncated', 'corrupt']) {
        expect(await cache.read(key), isNull);
        expect(await File('${directory.path}/${hash(key)}').exists(), isFalse);
      }
    },
  );

  test(
    'remove and clear preserve unrelated originals and nested directories',
    () async {
      final cache = create();
      await cache.write('a', bytes(1));
      await cache.write('b', bytes(2));
      await cache.remove('a');
      expect(await cache.read('a'), isNull);
      expect(await cache.read('b'), bytes(2));
      final original = File('${temporary.path}/original.ARW');
      await original.writeAsBytes([9, 8]);
      final unrelated = File('${directory.path}/holiday.JPG');
      await unrelated.writeAsBytes([4, 5]);
      final nested = Directory('${directory.path}/unrelated');
      await nested.create();
      await File('${nested.path}/original.ARW').writeAsBytes([3]);
      await Link('${directory.path}/${hash('outside')}').create(original.path);
      await cache.clear();
      expect(await cache.read('b'), isNull);
      expect(await original.readAsBytes(), [9, 8]);
      expect(await unrelated.readAsBytes(), [4, 5]);
      expect(await File('${nested.path}/original.ARW').readAsBytes(), [3]);
      await cache.close();
      expect(await create().read('b'), isNull);
    },
  );

  test('opaque camera/card/version keys cannot escape or collide', () async {
    final cache = create();
    final keys = [
      '../../outside.JPG',
      'camera-A/card-1/file/v1',
      'camera-A/card-2/file/v1',
      'camera-A/card-1/file/v2',
      'camera-B/card-1/file/v1',
      '相机\u0000卡/照片',
    ];
    for (var i = 0; i < keys.length; i++) {
      await cache.write(keys[i], bytes(i, 100));
    }
    for (var i = 0; i < keys.length; i++) {
      expect(await cache.read(keys[i]), bytes(i, 100));
      expect(await File('${directory.path}/${hash(keys[i])}').exists(), isTrue);
    }
    expect(await File('${temporary.path}/outside.JPG').exists(), isFalse);
  });

  test('serializes overlapping writes, remove, clear, and close', () async {
    final cache = create(maxBytes: 12000);
    await Future.wait([
      for (var i = 0; i < 25; i++) cache.write('same', bytes(i, 100)),
    ]);
    expect(await cache.read('same'), bytes(24, 100));
    final operations = [
      cache.write('a', bytes(1)),
      cache.remove('a'),
      cache.write('b', bytes(2)),
      cache.clear(),
      cache.write('final', bytes(3)),
    ];
    final closing = cache.close();
    await Future.wait(operations);
    await closing;
    await cache.close();
    final reopened = create(maxBytes: 12000);
    expect(await reopened.read('a'), isNull);
    expect(await reopened.read('b'), isNull);
    expect(await reopened.read('final'), bytes(3));
    expect(await cache.read('final'), isNull);
  });

  test(
    'initialization removes partials and orphans, never follows links',
    () async {
      await directory.create();
      final outside = File('${temporary.path}/original.ARW');
      await outside.writeAsBytes([8, 9]);
      await File('${directory.path}/${hash('orphan')}').writeAsBytes([1]);
      await File('${directory.path}/${hash('partial')}.part').writeAsBytes([2]);
      await Link('${directory.path}/${hash('link')}').create(outside.path);
      final cache = create();
      await cache.ready;
      expect(await cache.read('orphan'), isNull);
      expect(await outside.readAsBytes(), [8, 9]);
      final names = await directory
          .list()
          .map((f) => f.uri.pathSegments.last)
          .toList();
      expect(names, ['index.json']);
    },
  );

  test('corrupt index is discarded without reading arbitrary paths', () async {
    final cache = create();
    await cache.write('a', bytes(1));
    await cache.close();
    await File('${directory.path}/index.json').writeAsString('{broken');
    final reopened = create();
    expect(await reopened.read('a'), isNull);
    expect(await File('${directory.path}/${hash('a')}').exists(), isFalse);
  });

  test(
    'validates hostile sizes, timestamps, and hash names in index',
    () async {
      await directory.create();
      final outside = File('${temporary.path}/original.ARW');
      await outside.writeAsBytes([9]);
      final entries = [
        {'key': '../original.ARW', 'size': 1},
        {'key': hash('negative'), 'size': -1},
        {'key': hash('huge'), 'size': 1 << 62},
        {'key': hash('string'), 'size': '2000'},
        {'key': hash('future'), 'size': 2000, 'writtenAt': 1 << 62},
      ];
      await File('${directory.path}/index.json').writeAsString(
        jsonEncode({
          'version': 1,
          'entries': [
            for (final entry in entries)
              {
                'writtenAt': time.millisecondsSinceEpoch,
                'checksum': hash('data'),
                ...entry,
              },
          ],
        }),
      );
      final cache = create();
      await cache.ready;
      expect(await cache.read('huge'), isNull);
      expect(await outside.readAsBytes(), [9]);
      expect(await diskBytes(), lessThanOrEqualTo(32 * 1024));
    },
  );

  test('entry and index symlinks never read or overwrite originals', () async {
    final cache = create();
    await cache.write('a', bytes(1));
    final original = File('${temporary.path}/original.ARW');
    await original.writeAsBytes(bytes(9));
    final file = File('${directory.path}/${hash('a')}');
    await file.delete();
    await Link(file.path).create(original.path);
    expect(await cache.read('a'), isNull);
    await cache.write('a', bytes(2));
    expect(await original.readAsBytes(), bytes(9));
    await cache.close();
    await File('${directory.path}/index.json').delete();
    await Link('${directory.path}/index.json').create(original.path);
    final reopened = create();
    await reopened.ready;
    expect(await reopened.read('a'), isNull);
    expect(await original.readAsBytes(), bytes(9));
  });

  test('refuses a symlinked cache root or ancestor', () async {
    final originals = Directory('${temporary.path}/originals');
    await originals.create();
    final original = File('${originals.path}/photo.ARW');
    await original.writeAsBytes([9]);
    final link = Link(directory.path);
    await link.create(originals.path);
    final cache = create();
    await expectLater(cache.ready, throwsA(isA<FileSystemException>()));
    final nested = create(at: Directory('${link.path}/cache'));
    await expectLater(nested.ready, throwsA(isA<FileSystemException>()));
    expect(await original.readAsBytes(), [9]);
  });

  test(
    'failed staging preserves the previous complete entry and queue works',
    () async {
      final cache = create();
      await cache.write('a', bytes(1));
      final obstruction = Directory('${directory.path}/${hash('a')}.part');
      await obstruction.create();
      await expectLater(
        cache.write('a', bytes(2)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await cache.read('a'), bytes(1));
      await obstruction.delete();
      await cache.write('a', bytes(3));
      expect(await cache.read('a'), bytes(3));
    },
  );

  test(
    'failed index replacement restores the previous complete entry',
    () async {
      final cache = create();
      await cache.write('a', bytes(1));
      final obstruction = Directory('${directory.path}/index.json.part');
      await obstruction.create();
      await expectLater(
        cache.write('a', bytes(2)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await cache.read('a'), bytes(1));
      await obstruction.delete();
      await cache.close();
      expect(await create().read('a'), bytes(1));
    },
  );

  test('restart recovers old bytes from an interrupted replacement', () async {
    final cache = create();
    await cache.write('a', bytes(1));
    await cache.close();
    final target = File('${directory.path}/${hash('a')}');
    await target.rename('${target.path}.bak');
    await target.writeAsBytes(bytes(2));
    final reopened = create();
    expect(await reopened.read('a'), bytes(1));
    expect(await File('${target.path}.bak').exists(), isFalse);
  });

  test(
    'reopening with a smaller limit prunes actual files to its budget',
    () async {
      final cache = create();
      for (var i = 0; i < 8; i++) {
        await cache.write('$i', bytes(i));
      }
      await cache.close();
      final smaller = create(maxBytes: 6000);
      await smaller.ready;
      expect(await diskBytes(), lessThanOrEqualTo(6000));
      expect(await smaller.read('0'), isNull);
      expect(await smaller.read('7'), bytes(7));
    },
  );

  test(
    'tiny budgets remain usable for misses, remove, clear, and close',
    () async {
      final cache = create(maxBytes: 30);
      await cache.ready;
      await cache.write('cannot-fit', bytes(1, 1));
      expect(await cache.read('cannot-fit'), isNull);
      await cache.remove('absent');
      await cache.clear();
      await cache.close();
      expect(await diskBytes(), lessThanOrEqualTo(30));
    },
  );

  test(
    'concurrent distinct writes evict safely and survive reopening',
    () async {
      final cache = create(maxBytes: 6000);
      await Future.wait([
        for (var i = 0; i < 30; i++) cache.write('key-$i', bytes(i, 1000)),
      ]);
      await cache.close();
      expect(await diskBytes(), lessThanOrEqualTo(6000));
      final reopened = create(maxBytes: 6000);
      expect(await reopened.read('key-0'), isNull);
      expect(await reopened.read('key-29'), bytes(29, 1000));
    },
  );

  test(
    'startup expires entries and clears oversized corrupt manifests',
    () async {
      final cache = create(maxAge: const Duration(hours: 1));
      await cache.write('old', bytes(1));
      await cache.close();
      time = time.add(const Duration(hours: 1));
      final expired = create(maxAge: const Duration(hours: 1));
      await expired.ready;
      expect(await expired.read('old'), isNull);
      expect(await File('${directory.path}/${hash('old')}').exists(), isFalse);
      await expired.write('next', bytes(2));
      await expired.close();
      await File('${directory.path}/index.json').writeAsString(' ' * 40000);
      final recovered = create();
      await recovered.ready;
      expect(await recovered.read('next'), isNull);
      expect(await diskBytes(), lessThanOrEqualTo(32 * 1024));
    },
  );

  test(
    'committed replacement wins over a leftover backup on restart',
    () async {
      final cache = create();
      await cache.write('a', bytes(2));
      await cache.close();
      await File('${directory.path}/${hash('a')}.bak').writeAsBytes(bytes(1));
      final reopened = create();
      expect(await reopened.read('a'), bytes(2));
      expect(
        await File('${directory.path}/${hash('a')}.bak').exists(),
        isFalse,
      );
    },
  );

  test(
    'staging links are unlinked without overwriting their targets',
    () async {
      final cache = create();
      await cache.ready;
      final original = File('${temporary.path}/original.ARW');
      await original.writeAsBytes(bytes(9));
      await Link('${directory.path}/${hash('a')}.part').create(original.path);
      await Link('${directory.path}/${hash('a')}.bak').create(original.path);
      await Link('${directory.path}/index.json.part').create(original.path);
      await cache.write('a', bytes(1));
      expect(await cache.read('a'), bytes(1));
      expect(await original.readAsBytes(), bytes(9));
    },
  );

  test(
    'directory obstructions are preserved without recursive deletion',
    () async {
      final cache = create();
      await cache.ready;
      final obstruction = Directory('${directory.path}/${hash('a')}');
      await obstruction.create();
      final original = File('${obstruction.path}/original.ARW');
      await original.writeAsBytes([9]);
      await expectLater(
        cache.write('a', bytes(1)),
        throwsA(isA<FileSystemException>()),
      );
      await cache.remove('a');
      await cache.clear();
      expect(await original.readAsBytes(), [9]);
    },
  );

  test('rejects unsafe limits and writes after closing', () async {
    expect(() => create(maxBytes: 0), throwsArgumentError);
    expect(() => create(maxEntryBytes: 0), throwsArgumentError);
    expect(() => create(maxAge: Duration.zero), throwsArgumentError);
    final cache = create();
    await cache.close();
    await expectLater(cache.write('a', bytes(1)), throwsStateError);
    await expectLater(cache.remove('a'), throwsStateError);
    await expectLater(cache.clear(), throwsStateError);
    expect(await cache.read('a'), isNull);
  });
}
