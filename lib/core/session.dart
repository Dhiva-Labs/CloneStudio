import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One end of the wire protocol. The network [Session] implements both
/// sides; bundle files on a USB drive implement the same interfaces so the
/// transfer engine cannot tell a socket from a drive.
abstract class WireReader {
  Future<Map<String, dynamic>?> readJson({Duration timeout});
  Future<Uint8List?> readFrame({Duration timeout});
}

abstract class WireWriter {
  void sendJson(Map<String, dynamic> msg);
  void sendFrame(List<int> payload);
  Future<void> flush();
}

/// Buffered reader/writer over the TLS socket supporting two framings that
/// share one buffer: newline-delimited JSON for control messages and
/// 4-byte length-prefixed binary frames for bulk file data.
class Session implements WireReader, WireWriter {
  Session(this.socket) {
    socket.listen(_onData, onDone: _onDone, onError: (_) => _onDone());
    // Write failures (peer vanished mid-send) surface on `done`; without
    // this handler they become uncatchable async errors.
    socket.done.catchError((_) {
      _onDone();
    });
  }

  final SecureSocket socket;
  String peerName = '';
  bool closed = false;

  final _chunks = <Uint8List>[];
  int _buffered = 0;
  int _offset = 0; // consumed bytes inside _chunks.first
  Completer<void>? _wakeup;

  void _onData(Uint8List data) {
    if (data.isEmpty) return;
    _chunks.add(data);
    _buffered += data.length;
    _wakeup?.complete();
    _wakeup = null;
  }

  void _onDone() {
    closed = true;
    _wakeup?.complete();
    _wakeup = null;
  }

  Future<bool> _waitForMore(DateTime deadline) async {
    if (closed) return false;
    final remaining = deadline.difference(DateTime.now());
    if (remaining.isNegative) return false;
    final c = Completer<void>();
    _wakeup = c;
    try {
      await c.future.timeout(remaining);
      return true;
    } on TimeoutException {
      _wakeup = null;
      return false;
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

  /// Index of the next '\n' in unconsumed data, or -1.
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
    final deadline = DateTime.now().add(timeout);
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
      if (!await _waitForMore(deadline)) return null;
    }
  }

  @override
  Future<Uint8List?> readFrame(
      {Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (_buffered < 4) {
      if (!await _waitForMore(deadline)) return null;
    }
    final len = ByteData.sublistView(_take(4)).getUint32(0);
    while (_buffered < len) {
      if (!await _waitForMore(deadline)) return null;
    }
    return _take(len);
  }

  @override
  void sendJson(Map<String, dynamic> msg) {
    if (closed) throw const SocketException('connection closed');
    try {
      socket.add(utf8.encode('${jsonEncode(msg)}\n'));
    } catch (_) {
      closed = true;
      throw const SocketException('connection closed');
    }
  }

  @override
  void sendFrame(List<int> payload) {
    if (closed) throw const SocketException('connection closed');
    try {
      final head = ByteData(4)..setUint32(0, payload.length);
      socket.add(head.buffer.asUint8List());
      socket.add(payload);
    } catch (_) {
      closed = true;
      throw const SocketException('connection closed');
    }
  }

  @override
  Future<void> flush() async {
    if (closed) throw const SocketException('connection closed');
    try {
      await socket.flush();
    } catch (_) {
      closed = true;
      throw const SocketException('connection closed');
    }
  }

  void close() {
    closed = true;
    socket.destroy();
  }
}
