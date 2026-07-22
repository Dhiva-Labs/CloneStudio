import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import 'journal.dart';
import 'scanner.dart';
import 'session.dart';

const _chunkSize = 1024 * 1024;
const _flushEvery = 8 * 1024 * 1024; // keep memory flat without stalling
const _serveTimeout = Duration(days: 1); // humans pick modes slowly
const _dataTimeout = Duration(seconds: 60);

enum TransferState { idle, waiting, scanning, transferring, verifying, done, error }

/// Shared progress surface for every transfer UI (send, receive, export,
/// import) so the screens don't care which side they're showing.
abstract class ProgressSource extends ChangeNotifier {
  TransferState state = TransferState.idle;
  int totalBytes = 0;
  int doneBytes = 0;
  int totalFiles = 0;
  int doneFiles = 0;
  int skippedFiles = 0;
  String currentItem = '';
  String? errorMessage;
  DateTime? startedAt;

  double get progress => totalBytes == 0 ? 0 : doneBytes / totalBytes;

  /// Smoothed bytes/second since the transfer started.
  double get speed {
    final t = startedAt;
    if (t == null) return 0;
    final secs = DateTime.now().difference(t).inMilliseconds / 1000;
    return secs < 0.5 ? 0 : doneBytes / secs;
  }

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// Progress ticks arrive per megabyte; repainting the UI that often
  /// throttles the copy loop, so cap updates at ~10 per second.
  void notifyProgress() {
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds < 100) return;
    _lastNotify = now;
    notifyListeners();
  }

  void _setState(TransferState s) {
    state = s;
    notifyListeners();
  }

  void fail(String friendly) {
    errorMessage = friendly;
    _setState(TransferState.error);
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

/// OLD computer (or bundle exporter): walks the disk and streams entries.
class SenderController extends ProgressSource {
  SenderController(this.writer, [this.reader]);

  final WireWriter writer;
  final WireReader? reader; // null when writing a bundle (one-way)

  List<ScanCategory>? _scanned;

  /// Network mode: answer the new computer's requests until done.
  Future<void> serve() async {
    final r = reader!;
    _setState(TransferState.waiting);
    while (true) {
      final msg = await r.readJson(timeout: _serveTimeout);
      if (msg == null) {
        if (state != TransferState.done) {
          fail('The connection was lost. Open Clone Studio on both '
              'computers to continue where you left off.');
        }
        return;
      }
      switch (msg['type']) {
        case 'scan':
          _setState(TransferState.scanning);
          _scanned = await scanAll();
          writer.sendJson({
            'type': 'scan_result',
            'name': Platform.localHostname,
            'categories': [for (final c in _scanned!) c.toWire()],
          });
          await writer.flush();
          _setState(TransferState.waiting);
        case 'start':
          final selected = (msg['selected'] as List).cast<String>();
          final have = (msg['have'] as List? ?? [])
              .cast<Map<String, dynamic>>();
          await send(selected, have);
          if (state == TransferState.error) return;
          final ack = await r.readJson(timeout: _dataTimeout);
          if (ack?['type'] == 'ack') _setState(TransferState.done);
          return;
      }
    }
  }

  /// Streams the selected categories. Also used directly for bundle export.
  /// Never throws on a lost pipe — the fail-safe promise is that both sides
  /// end in a calm, resumable state.
  Future<void> send(List<String> selected,
      List<Map<String, dynamic>> have) async {
    try {
      await _send(selected, have);
    } on SocketException {
      fail('The connection was interrupted. Nothing is lost — reopen '
          'Clone Studio on both computers and it continues where it left off.');
    } on FileSystemException {
      fail('The drive was disconnected while writing. Plug it back in and '
          'start again — finished parts are kept.');
    }
  }

  Future<void> _send(List<String> selected,
      List<Map<String, dynamic>> have) async {
    final haveSet = {for (final h in have) '${h['p']}#${h['s']}'};
    final cats = (_scanned ?? await scanAll())
        .where((c) => selected.contains(c.id))
        .toList();

    // Enumerate first so the receiver gets honest totals.
    final all = <ScanEntry>[];
    for (final c in cats) {
      all.addAll(await scanCategory(c));
    }
    final toSend = <ScanEntry>[];
    for (final e in all) {
      if ((e.kind == 'file' || e.kind == 'virtual') &&
          haveSet.contains('${e.relative}#${e.size}')) {
        skippedFiles++;
        continue;
      }
      toSend.add(e);
    }
    totalFiles = toSend.where((e) => e.kind != 'dir').length;
    totalBytes = toSend.fold(0, (s, e) => s + e.size);
    startedAt = DateTime.now();
    writer.sendJson({
      'type': 'plan',
      'files': totalFiles,
      'bytes': totalBytes,
      'skipped': skippedFiles,
    });
    _setState(TransferState.transferring);

    for (final e in toSend) {
      currentItem = e.relative;
      switch (e.kind) {
        case 'dir':
          writer.sendJson({'type': 'dir', 'p': e.relative, 'mode': e.mode});
        case 'symlink':
          writer.sendJson(
              {'type': 'symlink', 'p': e.relative, 't': e.linkTarget});
          doneFiles++;
        case 'virtual':
          await _sendBytes(e.relative, e.mode, e.content!);
        case 'file':
          await _sendFile(e);
      }
      notifyProgress();
    }

    writer.sendJson({
      'type': 'complete',
      'files': doneFiles,
      'bytes': doneBytes,
      'skipped': skippedFiles,
    });
    await writer.flush();
    if (reader == null) _setState(TransferState.done); // bundle export ends here
  }

  Future<void> _sendBytes(String rel, int mode, List<int> content) async {
    writer.sendJson({
      'type': 'file',
      'p': rel,
      's': content.length,
      'mode': mode,
      'mtime': DateTime.now().millisecondsSinceEpoch,
    });
    for (var off = 0; off < content.length; off += _chunkSize) {
      final end = (off + _chunkSize).clamp(0, content.length);
      writer.sendFrame(content.sublist(off, end));
      doneBytes += end - off;
    }
    writer.sendJson({
      'type': 'file_end',
      'sha': crypto.sha256.convert(content).toString(),
    });
    await writer.flush();
    doneFiles++;
  }

  Future<void> _sendFile(ScanEntry e) async {
    final file = File(e.absolute);
    final stat = file.statSync();
    writer.sendJson({
      'type': 'file',
      'p': e.relative,
      's': e.size,
      'mode': e.mode,
      'mtime': stat.modified.millisecondsSinceEpoch,
    });
    final digestOut = _DigestSink();
    final digestIn = crypto.sha256.startChunkedConversion(digestOut);
    RandomAccessFile raf;
    try {
      raf = await file.open();
    } catch (_) {
      // Vanished or unreadable since scan: send empty + bad sha so the
      // receiver discards it rather than trusting a half-truth.
      digestIn.close();
      writer.sendJson({'type': 'file_end', 'sha': 'unreadable'});
      return;
    }
    var remaining = e.size;
    var sinceFlush = 0;
    while (remaining > 0) {
      final n = remaining < _chunkSize ? remaining : _chunkSize;
      final chunk = await raf.read(n);
      if (chunk.isEmpty) break; // truncated meanwhile
      digestIn.add(chunk);
      writer.sendFrame(chunk);
      doneBytes += chunk.length;
      remaining -= chunk.length;
      sinceFlush += chunk.length;
      if (sinceFlush >= _flushEvery) {
        await writer.flush(); // keeps memory flat on multi-GB files
        sinceFlush = 0;
      }
      notifyProgress();
    }
    await writer.flush();
    await raf.close();
    if (remaining > 0) {
      // File shrank while reading — pad protocol with zeros so framing
      // survives, then poison the hash so the receiver drops it.
      while (remaining > 0) {
        final n = remaining < _chunkSize ? remaining : _chunkSize;
        writer.sendFrame(Uint8List(n));
        doneBytes += n;
        remaining -= n;
      }
      digestIn.close();
      writer.sendJson({'type': 'file_end', 'sha': 'changed'});
    } else {
      digestIn.close();
      writer.sendJson({'type': 'file_end', 'sha': digestOut.value.toString()});
    }
    doneFiles++;
  }
}

/// NEW computer (or bundle importer): receives entries, writes atomically,
/// journals progress, verifies at the end.
class ReceiverController extends ProgressSource {
  ReceiverController(this.reader, [this.writer]);

  final WireReader reader;
  final WireWriter? writer; // null when importing from a bundle

  List<ScanCategory> categories = [];
  String peerName = '';
  int failedFiles = 0;
  Journal? _journal;

  /// Network mode: ask the old computer to size everything up.
  Future<bool> requestScan() async {
    _setState(TransferState.scanning);
    writer!.sendJson({'type': 'scan'});
    await writer!.flush();
    final msg =
        await reader.readJson(timeout: const Duration(minutes: 10));
    if (msg == null || msg['type'] != 'scan_result') {
      fail("The old computer didn't answer. Check it's still on and try again.");
      return false;
    }
    peerName = (msg['name'] as String?) ?? '';
    categories = [
      for (final w in (msg['categories'] as List).cast<Map<String, dynamic>>())
        ScanCategory(
          id: w['id'] as String,
          name: w['name'] as String,
          icon: w['icon'] as String,
          settings: w['settings'] as bool? ?? false,
        )
          ..sizeBytes = w['size'] as int
          ..fileCount = w['files'] as int
          ..available = w['available'] as bool? ?? true
          ..note = w['note'] as String?,
    ];
    _setState(TransferState.idle);
    return true;
  }

  /// Network mode: kick off the transfer for the chosen categories.
  Future<void> start(List<String> selectedIds) async {
    _journal = await Journal.open(targetRoot());
    writer!.sendJson({
      'type': 'start',
      'selected': selectedIds,
      'have': _journal!.toHave(targetRoot()),
    });
    await writer!.flush();
    await _receiveLoop();
  }

  /// Bundle mode: the whole conversation is already in the files.
  Future<void> importBundle() async {
    _journal = await Journal.open(targetRoot());
    await _receiveLoop();
  }

  Future<void> _receiveLoop() async {
    try {
      await _receiveLoopInner();
    } on _Interrupted {
      // fail() was already called with the friendly message
    }
  }

  Future<void> _receiveLoopInner() async {
    final root = targetRoot();
    final journal = _journal!;
    _setState(TransferState.transferring);
    startedAt = DateTime.now();

    while (true) {
      final msg = await reader.readJson(timeout: _dataTimeout);
      if (msg == null) {
        await journal.save();
        fail('The connection was interrupted. Nothing is lost — reopen '
            'Clone Studio on both computers and it continues from '
            '${(progress * 100).round()}%.');
        return;
      }
      switch (msg['type']) {
        case 'plan':
          totalFiles = msg['files'] as int;
          totalBytes = msg['bytes'] as int;
          skippedFiles = msg['skipped'] as int? ?? 0;
          notifyListeners();
        case 'dir':
          final dir = Directory('$root/${msg['p']}');
          await dir.create(recursive: true);
        case 'symlink':
          final path = '$root/${msg['p']}';
          try {
            if (FileSystemEntity.typeSync(path, followLinks: false) ==
                FileSystemEntityType.notFound) {
              await Link(path).create(msg['t'] as String, recursive: true);
            }
          } catch (_) {}
          doneFiles++;
        case 'file':
          await _receiveFile(root, journal, msg);
        case 'complete':
          await journal.save();
          _setState(TransferState.verifying);
          await _verify(root, journal);
          writer?.sendJson({'type': 'ack'});
          await writer?.flush();
          _setState(TransferState.done);
          return;
      }
    }
  }

  Future<void> _receiveFile(
      String root, Journal journal, Map<String, dynamic> msg) async {
    final rel = msg['p'] as String;
    final size = msg['s'] as int;
    final mode = msg['mode'] as int? ?? 420;
    final mtime = msg['mtime'] as int?;
    currentItem = rel;

    final alreadyHave = journal.has(rel, size) && File('$root/$rel').existsSync();

    var dest = '$root/$rel';
    if (!alreadyHave && File(dest).existsSync()) {
      dest = _keepBothPath(dest); // never silently overwrite what was there
    }

    final digestOut = _DigestSink();
    final digestIn = crypto.sha256.startChunkedConversion(digestOut);
    RandomAccessFile? raf;
    File? partial;
    if (!alreadyHave) {
      partial = File('$dest.partial');
      await partial.parent.create(recursive: true);
      raf = await partial.open(mode: FileMode.write);
    }

    var remaining = size;
    while (remaining > 0) {
      final chunk = await reader.readFrame(timeout: _dataTimeout);
      if (chunk == null) {
        await raf?.close();
        await journal.save();
        fail('The connection was interrupted. Nothing is lost — reopen '
            'Clone Studio on both computers to continue.');
        throw const _Interrupted();
      }
      digestIn.add(chunk);
      if (raf != null) await raf.writeFrom(chunk);
      remaining -= chunk.length;
      doneBytes += chunk.length;
      notifyProgress();
    }
    digestIn.close();

    final end = await reader.readJson(timeout: _dataTimeout);
    final wantSha = end?['sha'] as String?;
    final gotSha = digestOut.value?.toString() ?? '';

    if (alreadyHave) {
      doneFiles++;
      return; // consumed and discarded — resume skip for bundle imports
    }

    if (end == null || end['type'] != 'file_end' || wantSha != gotSha) {
      await raf!.close();
      await partial!.delete();
      failedFiles++;
      notifyListeners();
      return; // corrupted or changed underway — better absent than wrong
    }

    await raf!.flush(); // on disk before the rename makes it "real"
    await raf.close();
    await partial!.rename(dest);
    if (mode != 420 && mode != 436) {
      try {
        await Process.run('chmod', [mode.toRadixString(8), dest]);
      } catch (_) {}
    }
    if (mtime != null) {
      try {
        await File(dest)
            .setLastModified(DateTime.fromMillisecondsSinceEpoch(mtime));
      } catch (_) {}
    }
    await journal.add(rel, size, gotSha);
    doneFiles++;
  }

  String _keepBothPath(String dest) {
    final slash = dest.lastIndexOf('/');
    final dir = dest.substring(0, slash);
    final name = dest.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var candidate = '$dir/$stem (from old computer)$ext';
    var i = 2;
    while (File(candidate).existsSync()) {
      candidate = '$dir/$stem (from old computer $i)$ext';
      i++;
    }
    return candidate;
  }

  /// Quick end-of-run audit: everything journaled must exist with the
  /// right size.
  Future<void> _verify(String root, Journal journal) async {
    for (final e in journal.done.entries) {
      final f = File('$root/${e.key}');
      final want = (e.value as Map)['s'] as int;
      if (!f.existsSync() || f.lengthSync() != want) {
        failedFiles++;
      }
    }
    notifyListeners();
  }
}

class _Interrupted implements Exception {
  const _Interrupted();
}
