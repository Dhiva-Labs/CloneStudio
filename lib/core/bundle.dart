import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'session.dart';

/// USB-drive transport: the exact byte stream that would have crossed the
/// network is written into `CloneStudio/bundle-NNN.csb` files instead
/// (split so FAT32's 4 GB limit never bites), and read back on the new
/// computer. Same engine, different pipe — and permissions/symlinks survive
/// any drive filesystem because they live inside the stream, not on it.
const bundleDirName = 'CloneStudio';

/// 3.5 GB in production; tests shrink it to exercise multi-part bundles.
int bundlePartLimit = 3758096384;

class BundleWriter implements WireWriter {
  BundleWriter(this.baseDir);

  final String baseDir; // mount point of the drive
  RandomAccessFile? _raf;
  int _part = 0;
  int _written = 0;

  String get dir => '$baseDir/$bundleDirName';

  Future<void> open() async {
    final d = Directory(dir);
    if (d.existsSync()) await d.delete(recursive: true); // fresh export
    await d.create(recursive: true);
    await _nextPart();
  }

  Future<void> _nextPart() async {
    await _raf?.flush();
    await _raf?.close();
    _part++;
    _written = 0;
    final name =
        '$dir/bundle-${_part.toString().padLeft(3, '0')}.csb';
    _raf = await File(name).open(mode: FileMode.write);
  }

  void _write(List<int> bytes) {
    _raf!.writeFromSync(bytes);
    _written += bytes.length;
  }

  @override
  void sendJson(Map<String, dynamic> msg) {
    if (_written > bundlePartLimit) {
      // Split between messages only; readers treat parts as one stream.
      _nextPartSync();
    }
    _write(utf8.encode('${jsonEncode(msg)}\n'));
  }

  void _nextPartSync() {
    _raf!.flushSync();
    _raf!.closeSync();
    _part++;
    _written = 0;
    final name =
        '$dir/bundle-${_part.toString().padLeft(3, '0')}.csb';
    _raf = File(name).openSync(mode: FileMode.write);
  }

  @override
  void sendFrame(List<int> payload) {
    final head = ByteData(4)..setUint32(0, payload.length);
    _write(head.buffer.asUint8List());
    _write(payload);
  }

  @override
  Future<void> flush() async => _raf!.flushSync();

  Future<void> writeManifest(Map<String, dynamic> manifest) async {
    final tmp = File('$dir/manifest.json.tmp');
    await tmp.writeAsString(jsonEncode(manifest), flush: true);
    await tmp.rename('$dir/manifest.json');
  }

  Future<void> close() async {
    await _raf?.flush();
    await _raf?.close();
    _raf = null;
  }
}

class BundleReader implements WireReader {
  BundleReader(this.baseDir);

  final String baseDir;

  late final List<File> _parts = (Directory('$baseDir/$bundleDirName')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.csb'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      .toList();

  int _partIx = 0;
  RandomAccessFile? _raf;

  final _chunks = <Uint8List>[];
  int _buffered = 0;
  int _offset = 0;

  static Map<String, dynamic>? readManifest(String baseDir) {
    final f = File('$baseDir/$bundleDirName/manifest.json');
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Pull more bytes from the part files. False at end of bundle.
  Future<bool> _fill() async {
    while (true) {
      if (_raf == null) {
        if (_partIx >= _parts.length) return false;
        _raf = await _parts[_partIx].open();
        _partIx++;
      }
      final chunk = await _raf!.read(256 * 1024);
      if (chunk.isEmpty) {
        await _raf!.close();
        _raf = null;
        continue;
      }
      _chunks.add(chunk);
      _buffered += chunk.length;
      return true;
    }
  }

  Uint8List _take(int n) {
    final out = Uint8List(n);
    var written = 0;
    while (written < n) {
      final head = _chunks.first;
      final avail = head.length - _offset;
      final need = n - written;
      if (avail <= need) {
        out.setRange(written, written + avail, head, _offset);
        written += avail;
        _chunks.removeAt(0);
        _offset = 0;
      } else {
        out.setRange(written, written + need, head, _offset);
        _offset += need;
        written = n;
      }
    }
    _buffered -= n;
    return out;
  }

  int _indexOfNewline() {
    var linear = 0;
    for (var ci = 0; ci < _chunks.length; ci++) {
      final c = _chunks[ci];
      final start = ci == 0 ? _offset : 0;
      for (var i = start; i < c.length; i++) {
        if (c[i] == 10) return linear + (i - start);
      }
      linear += c.length - start;
    }
    return -1;
  }

  @override
  Future<Map<String, dynamic>?> readJson(
      {Duration timeout = const Duration(seconds: 30)}) async {
    while (true) {
      final idx = _indexOfNewline();
      if (idx >= 0) {
        final line = utf8.decode(_take(idx + 1)).trimRight();
        if (line.isEmpty) continue;
        try {
          return jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          return null;
        }
      }
      if (!await _fill()) return null;
    }
  }

  @override
  Future<Uint8List?> readFrame(
      {Duration timeout = const Duration(seconds: 30)}) async {
    while (_buffered < 4) {
      if (!await _fill()) return null;
    }
    final len = ByteData.sublistView(_take(4)).getUint32(0);
    while (_buffered < len) {
      if (!await _fill()) return null;
    }
    return _take(len);
  }
}

/// A place a bundle could live: a mounted removable drive, or a directory
/// given via CLONE_STUDIO_DRIVE_DIR for testing.
class DriveLocation {
  DriveLocation(this.label, this.path, this.freeBytes, this.hasBundle);
  final String label;
  final String path;
  final int freeBytes;
  final bool hasBundle;
}

Future<List<DriveLocation>> listDrives() async {
  final out = <DriveLocation>[];
  final user = Platform.environment['USER'] ?? '';
  final roots = <String>[
    '/media/$user',
    '/run/media/$user',
    if (Platform.environment['CLONE_STUDIO_DRIVE_DIR'] != null)
      Platform.environment['CLONE_STUDIO_DRIVE_DIR']!,
  ];
  for (final root in roots) {
    final rd = Directory(root);
    if (!rd.existsSync()) continue;
    final isOverride = root == Platform.environment['CLONE_STUDIO_DRIVE_DIR'];
    final candidates = isOverride
        ? [rd]
        : rd.listSync().whereType<Directory>().toList();
    for (final d in candidates) {
      int free = 0;
      try {
        final res = await Process.run('df', ['-B1', '--output=avail', d.path]);
        if (res.exitCode == 0) {
          free = int.parse((res.stdout as String).trim().split('\n').last.trim());
        }
      } catch (_) {}
      out.add(DriveLocation(
        d.path.split('/').last,
        d.path,
        free,
        File('${d.path}/$bundleDirName/manifest.json').existsSync(),
      ));
    }
  }
  return out;
}
