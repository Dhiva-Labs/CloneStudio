import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// UDP discovery: the old computer answers probes, the new computer sends
/// them. Pure sockets — works on any LAN and over a direct link-local cable,
/// no avahi dependency. Loopback is probed too so two instances on one
/// machine can find each other (used for testing and demos).
const discoveryPort = 42424;
const _app = 'clone_studio';

class RemoteDevice {
  RemoteDevice(this.name, this.os, this.address, this.port);
  final String name;
  final String os;
  final InternetAddress address;
  final int port;
  DateTime lastSeen = DateTime.now();
}

/// Runs on the OLD computer: replies "here" to every probe.
class Advertiser {
  RawDatagramSocket? _socket;

  /// Random per-instance id so a device reachable via several addresses
  /// (loopback + LAN, or Wi-Fi + ethernet) shows up only once.
  final String _id =
      List.generate(16, (_) => Random().nextInt(16).toRadixString(16)).join();

  Future<void> start(
      {required String name, required String os, required int tlsPort}) async {
    final s = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, discoveryPort,
        reusePort: true);
    _socket = s;
    s.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = s.receive();
      if (dg == null) return;
      try {
        final msg = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
        if (msg['app'] == _app && msg['type'] == 'probe') {
          final reply = jsonEncode({
            'app': _app,
            'type': 'here',
            'v': 1,
            'id': _id,
            'name': name,
            'os': os,
            'port': tlsPort,
          });
          s.send(utf8.encode(reply), dg.address, dg.port);
        }
      } catch (_) {} // ignore malformed packets
    });
  }

  void stop() {
    _socket?.close();
    _socket = null;
  }
}

/// Runs on the NEW computer: probes every second, collects replies.
class Browser extends ChangeNotifier {
  final devices = <String, RemoteDevice>{};
  RawDatagramSocket? _socket;
  Timer? _timer;

  Future<void> start() async {
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    s.broadcastEnabled = true;
    _socket = s;
    s.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = s.receive();
      if (dg == null) return;
      try {
        final msg = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
        if (msg['app'] == _app && msg['type'] == 'here') {
          final d = RemoteDevice(msg['name'] as String, msg['os'] as String,
              dg.address, msg['port'] as int);
          // Prefer the first address we heard a device on (loopback replies
          // arrive first for a same-machine instance, LAN for real ones).
          final key = (msg['id'] as String?) ?? '${d.name}@${d.address.address}';
          if (!devices.containsKey(key)) {
            devices[key] = d;
            notifyListeners();
          }
        }
      } catch (_) {}
    });
    _probe();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _probe());
  }

  void _probe() {
    final s = _socket;
    if (s == null) return;
    final probe =
        utf8.encode(jsonEncode({'app': _app, 'type': 'probe', 'v': 1}));
    for (final target in [
      InternetAddress('255.255.255.255'),
      InternetAddress.loopbackIPv4,
    ]) {
      try {
        s.send(probe, target, discoveryPort);
      } catch (_) {}
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
