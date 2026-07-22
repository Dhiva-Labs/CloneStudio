import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import 'discovery.dart';
import 'identity.dart';
import 'session.dart';

export 'session.dart' show Session;

/// MAC binding the PIN to the TLS certificate fingerprint the client saw.
/// A man-in-the-middle presents its own certificate, so its fingerprint
/// won't match and the MAC verification fails on the server.
List<int> _mac(String pin, List<int> salt, List<int> nonce, List<int> fp) {
  final key = crypto.Hmac(crypto.sha256, utf8.encode(pin)).convert(salt).bytes;
  return crypto.Hmac(crypto.sha256, key).convert([...nonce, ...fp]).bytes;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

List<int> _randBytes(int n) {
  final r = Random.secure();
  return List.generate(n, (_) => r.nextInt(256));
}

String _randomPin() {
  final r = Random.secure();
  return List.generate(6, (_) => r.nextInt(10)).join();
}

/// OLD computer: accepts one connection and checks its PIN.
/// After three wrong guesses the PIN is regenerated.
class PairingServer extends ChangeNotifier {
  PairingServer(this.identity);

  final Identity identity;

  String pin = _randomPin();
  int port = 0;
  Session? session;
  int _attempts = 0;
  SecureServerSocket? _server;

  Future<void> start() async {
    SecureServerSocket server;
    try {
      server = await SecureServerSocket.bind(
          InternetAddress.anyIPv4, 42425, identity.context);
    } on SocketException {
      // Port taken (another instance?) — any free port works, discovery
      // advertises the real one.
      server = await SecureServerSocket.bind(
          InternetAddress.anyIPv4, 0, identity.context);
    }
    _server = server;
    port = server.port;
    server.listen(_handle, onError: (_) {});
    notifyListeners();
  }

  Future<void> _handle(SecureSocket socket) async {
    if (session != null) {
      socket.destroy();
      return;
    }
    final s = Session(socket);
    try {
      final hello = await s.readJson();
      if (hello == null || hello['type'] != 'hello') {
        s.close();
        return;
      }
      final nonce = _randBytes(16);
      final salt = _randBytes(16);
      s.sendJson({
        'type': 'challenge',
        'nonce': base64Encode(nonce),
        'salt': base64Encode(salt),
      });
      final auth = await s.readJson();
      if (auth == null || auth['type'] != 'auth') {
        s.close();
        return;
      }
      final expected = _mac(pin, salt, nonce, identity.fingerprint);
      final got = base64Decode(auth['mac'] as String);
      if (!_sameBytes(expected, got)) {
        _attempts++;
        if (_attempts >= 3) {
          pin = _randomPin();
          _attempts = 0;
        }
        s.sendJson({'type': 'bad'});
        await socket.flush();
        s.close();
        notifyListeners();
        return;
      }
      s.peerName = (hello['name'] as String?) ?? 'New computer';
      s.sendJson({'type': 'ok', 'name': identity.deviceName});
      session = s;
      notifyListeners();
    } catch (_) {
      socket.destroy();
    }
  }

  /// Stops listening for new connections; an established session stays open.
  void stop() {
    _server?.close();
    _server = null;
  }
}

class PairingException implements Exception {
  PairingException(this.friendly);
  final String friendly;
}

/// NEW computer: connects and proves it knows the PIN.
class PairingClient {
  static Future<Session> pair(RemoteDevice device, String pin,
      {required String myName}) async {
    SecureSocket socket;
    try {
      socket = await SecureSocket.connect(device.address, device.port,
          onBadCertificate: (_) => true,
          timeout: const Duration(seconds: 8));
    } catch (_) {
      throw PairingException(
          "Couldn't reach the old computer. Make sure it's still on the "
          'same network and Clone Studio is open.');
    }
    final cert = socket.peerCertificate;
    if (cert == null) {
      socket.destroy();
      throw PairingException('Secure connection failed. Please try again.');
    }
    final fp = crypto.sha256.convert(cert.der).bytes;
    final s = Session(socket);
    s.sendJson({'type': 'hello', 'name': myName});
    final challenge = await s.readJson();
    if (challenge == null || challenge['type'] != 'challenge') {
      s.close();
      throw PairingException(
          "The old computer didn't answer. Please try again.");
    }
    final mac = _mac(
      pin,
      base64Decode(challenge['salt'] as String),
      base64Decode(challenge['nonce'] as String),
      fp,
    );
    s.sendJson({'type': 'auth', 'mac': base64Encode(mac)});
    final result = await s.readJson();
    if (result == null || result['type'] != 'ok') {
      s.close();
      throw PairingException(
          "That code didn't match. Check the big code on the old "
          "computer's screen and try again.");
    }
    s.peerName = (result['name'] as String?) ?? device.name;
    return s;
  }
}
