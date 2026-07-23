import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import '../models/selection.dart';
import 'journal.dart';
import 'scanner.dart';
import 'session.dart';

const _chunkSize = 1024 * 1024;
const _flushEvery = 8 * 1024 * 1024; // keep memory flat without stalling
const _serveTimeout = Duration(days: 1); // humans pick modes slowly
const _dataTimeout = Duration(seconds: 60);

enum TransferState { idle, waiting, offering, transferring, verifying, done, error }

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

  void setState_(TransferState s) {
    state = s;
    notifyListeners();
  }

  void fail(String friendly) {
    errorMessage = friendly;
    setState_(TransferState.error);
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
///
/// The source pre-selects on its own screen; over the network it first
/// *offers* that selection so the new computer can review and trim it, then
/// streams only what the new computer confirms.
class SenderController extends ProgressSource {
  SenderController(this.writer, [this.reader]);

  final WireWriter writer;
  final WireReader? reader; // null when writing a bundle (one-way)

  List<ScanEntry> _entries = [];
  Set<String> _selection = {}; // the source's own picks (rel paths of leaves)
  List<ScanCategory> _cats = [];

  /// Called before serve()/exportBundle with the local scan + the user's
  /// selection made on this computer.
  void setPlan(ScanResult scan, Set<String> selectedRels) {
    _entries = scan.entries;
    _cats = scan.categories;
    _selection = selectedRels;
  }

  List<Map<String, dynamic>> _offerLeaves() => [
        for (final e in _entries)
          if (e.kind != 'dir' && _selection.contains(e.relative))
            Leaf(e.relative, e.size, e.kind, e.categoryId).toWire(),
      ];

  List<Map<String, dynamic>> _offerCats() => [
        for (final c in _cats)
          if (c.available)
            {'id': c.id, 'name': c.name, 'icon': c.icon, 'settings': c.settings},
      ];

  /// Network mode: offer the selection, wait for the trimmed confirmation,
  /// then stream it.
  Future<void> serve() async {
    final r = reader!;
    setState_(TransferState.offering);
    try {
      writer.sendJson({
        'type': 'offer',
        'name': Platform.localHostname,
        'cats': _offerCats(),
        'leaves': _offerLeaves(),
      });
      await writer.flush();
    } on SocketException {
      fail('The connection was lost. Reopen Clone Studio on both computers.');
      return;
    }
    setState_(TransferState.waiting);
    final msg = await r.readJson(timeout: _serveTimeout);
    if (msg == null || msg['type'] != 'start') {
      fail('The other computer disconnected before choosing. Please try again.');
      return;
    }
    final include = (msg['include'] as List).cast<String>().toSet();
    final have = (msg['have'] as List? ?? []).cast<Map<String, dynamic>>();
    await send(include, have);
    if (state == TransferState.error) return;
    final ack = await r.readJson(timeout: _dataTimeout);
    if (ack?['type'] == 'ack') setState_(TransferState.done);
  }

  /// Bundle export: stream the source's whole selection into the drive; the
  /// new computer trims it on import.
  Future<void> exportBundle() => send(_selection, []);

  /// Streams the [include] set (already a subset of the source's selection),
  /// skipping anything the target reports it already [have]s. Never throws on
  /// a lost pipe — both sides must end in a calm, resumable state.
  Future<void> send(Set<String> include, List<Map<String, dynamic>> have) async {
    try {
      await _send(include, have);
    } on SocketException {
      fail('The connection was interrupted. Nothing is lost — reopen '
          'Clone Studio on both computers and it continues where it left off.');
    } on FileSystemException {
      fail('The drive was disconnected while writing. Plug it back in and '
          'start again — finished parts are kept.');
    }
  }

  Future<void> _send(
      Set<String> include, List<Map<String, dynamic>> have) async {
    final haveSet = {for (final h in have) '${h['p']}#${h['s']}'};

    // Directories that are ancestors of an included leaf must travel (for
    // their permissions and to hold empty structure).
    final ancestors = <String>{};
    for (final rel in include) {
      var i = rel.lastIndexOf('/');
      while (i > 0) {
        ancestors.add(rel.substring(0, i));
        i = rel.lastIndexOf('/', i - 1);
      }
    }

    final seen = <String>{};
    final toSend = <ScanEntry>[];
    final selectedApps = <ScanEntry>[];
    for (final e in _entries) {
      if (!seen.add(e.relative)) continue; // dedup overlapping categories
      if (e.kind == 'dir') {
        if (ancestors.contains(e.relative)) toSend.add(e);
        continue;
      }
      if (!include.contains(e.relative)) continue;
      if (e.kind == 'app') {
        selectedApps.add(e); // reinstalled from a list, not copied
        continue;
      }
      if ((e.kind == 'file' || e.kind == 'virtual') &&
          haveSet.contains('${e.relative}#${e.size}')) {
        skippedFiles++;
        continue;
      }
      toSend.add(e);
    }

    // Selected apps become the generated reinstall files.
    for (final v in renderAppList(selectedApps)) {
      if (haveSet.contains('${v.relative}#${v.size}')) {
        skippedFiles++;
        continue;
      }
      toSend.add(v);
    }

    totalFiles = toSend.where((e) => e.kind != 'dir').length;
    totalBytes = toSend.fold(0, (s, e) => s + e.size);
    startedAt = DateTime.now();
    writer.sendJson({
      'type': 'plan',
      'name': Platform.localHostname,
      'files': totalFiles,
      'bytes': totalBytes,
      'skipped': skippedFiles,
    });
    setState_(TransferState.transferring);

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
    if (reader == null) setState_(TransferState.done); // bundle export ends here
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

/// NEW computer (or bundle importer): reviews the offer, then receives the
/// confirmed set, writing atomically, journaling progress, verifying.
class ReceiverController extends ProgressSource {
  ReceiverController(this.reader, [this.writer]);

  final WireReader reader;
  final WireWriter? writer; // null when importing from a bundle

  String peerName = '';
  List<ScanCategory> offerCats = [];
  List<Leaf> offerLeaves = [];

  int failedFiles = 0;
  Journal? _journal;
  Set<String>? _includeFilter; // bundle import: only write these
  int? _plannedBytes; // bundle import: honest total after trimming

  /// Network mode: read the source's offer so the review screen can build a
  /// selection tree from it.
  Future<bool> receiveOffer() async {
    setState_(TransferState.offering);
    final msg = await reader.readJson(timeout: const Duration(minutes: 10));
    if (msg == null || msg['type'] != 'offer') {
      fail("The old computer didn't send anything. Check it's still on and "
          'try again.');
      return false;
    }
    peerName = (msg['name'] as String?) ?? '';
    offerCats = [
      for (final w in (msg['cats'] as List).cast<Map<String, dynamic>>())
        ScanCategory(
          id: w['id'] as String,
          name: w['name'] as String,
          icon: w['icon'] as String,
          settings: w['settings'] as bool? ?? false,
        )..available = true,
    ];
    offerLeaves = [
      for (final w in (msg['leaves'] as List).cast<Map<String, dynamic>>())
        Leaf.fromWire(w),
    ];
    setState_(TransferState.idle);
    return true;
  }

  /// Network mode: confirm the trimmed [include] set and receive it.
  Future<void> startReceive(Set<String> include) async {
    _journal = await Journal.open(targetRoot());
    writer!.sendJson({
      'type': 'start',
      'include': include.toList(),
      'have': _journal!.toHave(targetRoot()),
    });
    await writer!.flush();
    await _receiveLoop();
  }

  /// Bundle mode: [include] filters which files from the bundle to restore.
  Future<void> importBundle(Set<String> include, List<Leaf> manifestLeaves,
      {String peer = ''}) async {
    peerName = peer;
    _includeFilter = include;
    _plannedBytes = manifestLeaves
        .where((l) => include.contains(l.rel))
        .fold<int>(0, (s, l) => s + l.size);
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
    setState_(TransferState.transferring);
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
          totalBytes = _plannedBytes ?? msg['bytes'] as int;
          skippedFiles = msg['skipped'] as int? ?? 0; // resume skips
          if (peerName.isEmpty) peerName = (msg['name'] as String?) ?? '';
          // Guard the target's disk before we start writing.
          final need = _plannedBytes ?? (msg['bytes'] as int);
          final free = await freeBytes(root);
          if (free < need + (need ~/ 20)) {
            fail('Not enough space on this computer. This needs '
                '${_fmtGb(need)} but only ${_fmtGb(free)} is free. '
                'Free up some space, or go back and pick fewer files.');
            return;
          }
          notifyListeners();
        case 'dir':
          await Directory('$root/${msg['p']}').create(recursive: true);
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
          setState_(TransferState.verifying);
          await _verify(root, journal);
          writer?.sendJson({'type': 'ack'});
          await writer?.flush();
          setState_(TransferState.done);
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

    final trimmedOut = _includeFilter != null && !_includeFilter!.contains(rel);
    final alreadyHave =
        journal.has(rel, size) && File('$root/$rel').existsSync();
    // "consume without writing": bundle files the user unticked, or files a
    // resume already completed.
    final skip = trimmedOut || alreadyHave;

    var dest = '$root/$rel';
    if (!skip && File(dest).existsSync()) {
      dest = _keepBothPath(dest); // never silently overwrite what was there
    }

    final digestOut = _DigestSink();
    final digestIn = crypto.sha256.startChunkedConversion(digestOut);
    RandomAccessFile? raf;
    File? partial;
    if (!skip) {
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

    if (skip) {
      doneFiles++;
      return;
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

String _fmtGb(int bytes) {
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  return '${(bytes / mb).round()} MB';
}
