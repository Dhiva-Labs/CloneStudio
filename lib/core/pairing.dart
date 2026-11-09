import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import 'discovery.dart';
import 'identity.dart';
import 'pake.dart';
import 'session.dart';

export 'session.dart' show Session;

/// Pairing protocol version. Version 1 had the new computer send a MAC
/// keyed by the PIN and then trust a bare "ok": the old computer never
/// proved it knew the PIN, and whoever received that MAC could recover the
/// six digits offline in under a second. Version 2 is a password-
/// authenticated key exchange with confirmation in both directions (see
/// pake.dart).
const pairingVersion = 2;

List<int>? _decode(Object? value, {int? length}) {
  if (value is! String) return null;
  try {
    final bytes = base64Decode(value);
    if (length != null && bytes.length != length) return null;
    return bytes;
  } on FormatException {
    return null;
  }
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
/// Every exchange lets the other side test exactly one PIN, so each one
/// counts as a guess whether or not it is completed; after three the PIN is
/// regenerated.
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
      final clientShare = _decode(hello['share'], length: 32);
      if (hello['v'] != pairingVersion || clientShare == null) {
        // An older Clone Studio. Tell it so rather than leaving it to guess.
        s.sendJson({'type': 'upgrade', 'v': pairingVersion});
        await socket.flush();
        s.close();
        return;
      }
      // Our reply carries a confirmation the peer can check one PIN
      // against, so the guess is spent the moment we answer, not when (or
      // if) the peer reports back. Counted before any await so that
      // connections opened in parallel cannot each get a free try.
      _rotateIfSpent();
      _attempts++;
      final secret = _randBytes(32);
      final serverShare =
          pakeShare(secret, pakeGenerator(pin, identity.fingerprint));
      final keys = pakeKeys(
        secret: secret,
        peerShare: clientShare,
        clientShare: clientShare,
        serverShare: serverShare,
        fingerprint: identity.fingerprint,
      );
      if (keys == null) {
        _rotateIfSpent();
        s.close();
        notifyListeners();
        return;
      }
      s.sendJson({
        'type': 'pake',
        'share': base64Encode(serverShare),
        'confirm': base64Encode(keys.serverConfirm),
      });
      final auth = await s.readJson();
      final got =
          auth != null && auth['type'] == 'confirm' ? _decode(auth['confirm']) : null;
      if (got == null || !_sameBytes(keys.clientConfirm, got)) {
        _rotateIfSpent();
        s.sendJson({'type': 'bad'});
        await socket.flush();
        s.close();
        notifyListeners();
        return;
      }
      _attempts = 0;
      s.peerName = (hello['name'] as String?) ?? 'New computer';
      s.sendJson({'type': 'ok', 'name': identity.deviceName});
      session = s;
      notifyListeners();
    } catch (_) {
      socket.destroy();
    }
  }

  void _rotateIfSpent() {
    if (_attempts >= 3) {
      pin = _randomPin();
      _attempts = 0;
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

/// NEW computer: connects, proves it knows the PIN, and requires the same
/// proof from the old computer before trusting anything it sends.
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
    final secret = _randBytes(32);
    final share = pakeShare(secret, pakeGenerator(pin, fp));
    s.sendJson({
      'type': 'hello',
      'v': pairingVersion,
      'name': myName,
      'share': base64Encode(share),
    });
    final reply = await s.readJson();
    if (reply != null &&
        (reply['type'] == 'challenge' || reply['type'] == 'upgrade')) {
      s.close();
      throw PairingException(
          'The two computers are running different versions of Clone '
          'Studio. Update it on both and try again.');
    }
    if (reply == null || reply['type'] != 'pake') {
      s.close();
      throw PairingException(
          "The old computer didn't answer. Please try again.");
    }
    final serverShare = _decode(reply['share'], length: 32);
    final serverConfirm = _decode(reply['confirm']);
    final keys = serverShare == null
        ? null
        : pakeKeys(
            secret: secret,
            peerShare: serverShare,
            clientShare: share,
            serverShare: serverShare,
            fingerprint: fp,
          );
    // The other side must prove it knows the code too. Without this, any
    // machine on the network could answer as "the old computer" and push
    // files into this one.
    if (keys == null ||
        serverConfirm == null ||
        !_sameBytes(keys.serverConfirm, serverConfirm)) {
      s.close();
      throw PairingException(
          "That code didn't match. Check the big code on the old "
          "computer's screen and try again.");
    }
    s.sendJson({'type': 'confirm', 'confirm': base64Encode(keys.clientConfirm)});
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
