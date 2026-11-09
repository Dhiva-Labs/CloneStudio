import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// A password-authenticated key exchange for the pairing PIN, in the shape
/// of CPace over Curve25519.
///
/// The PIN is six digits. Any protocol that sends a MAC keyed by it hands
/// the other side a transcript it can test all million PINs against in
/// under a second, and then that side knows the PIN. Here the PIN only
/// picks the Diffie-Hellman generator, so each run lets the peer test the
/// single PIN it committed to before it saw anything: one guess per
/// connection, counted and rate-limited by the server, and nothing to
/// search offline.
///
/// Both confirmations are bound to the TLS certificate fingerprint each
/// side sees, so messages relayed through a man-in-the-middle's own TLS
/// sessions produce confirmations that do not match.
///
/// The field arithmetic uses BigInt and is not constant-time. The secrets
/// here are single-use and the exchange runs once, on a local network,
/// under the user's eyes, which is why that trade is acceptable.

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _a24 = BigInt.from(121665);
final BigInt _curveA = BigInt.from(486662);

BigInt _decodeLE(List<int> bytes) {
  var x = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    x = (x << 8) | BigInt.from(bytes[i]);
  }
  return x;
}

Uint8List _encodeLE(BigInt x) {
  final out = Uint8List(32);
  final mask = BigInt.from(0xff);
  var v = x;
  for (var i = 0; i < 32; i++) {
    out[i] = (v & mask).toInt();
    v >>= 8;
  }
  return out;
}

/// X25519 as in RFC 7748: scalar multiplication on the Montgomery
/// u-coordinate, with the scalar clamped.
Uint8List x25519(List<int> scalar, List<int> u) {
  if (scalar.length != 32 || u.length != 32) {
    throw ArgumentError('x25519 takes 32-byte inputs');
  }
  final k = Uint8List.fromList(scalar);
  k[0] &= 248;
  k[31] &= 127;
  k[31] |= 64;
  final uu = Uint8List.fromList(u);
  uu[31] &= 127;

  final x1 = _decodeLE(uu) % _p;
  final kn = _decodeLE(k);
  var x2 = BigInt.one, z2 = BigInt.zero, x3 = x1, z3 = BigInt.one;
  var swap = false;
  for (var t = 254; t >= 0; t--) {
    final bit = ((kn >> t) & BigInt.one) == BigInt.one;
    if (swap != bit) {
      final tx = x2;
      x2 = x3;
      x3 = tx;
      final tz = z2;
      z2 = z3;
      z3 = tz;
    }
    swap = bit;
    final a = (x2 + z2) % _p;
    final aa = (a * a) % _p;
    final b = (x2 - z2) % _p;
    final bb = (b * b) % _p;
    final e = (aa - bb) % _p;
    final c = (x3 + z3) % _p;
    final d = (x3 - z3) % _p;
    final da = (d * a) % _p;
    final cb = (c * b) % _p;
    final s = (da + cb) % _p;
    final m = (da - cb) % _p;
    x3 = (s * s) % _p;
    z3 = (x1 * ((m * m) % _p)) % _p;
    x2 = (aa * bb) % _p;
    z2 = (e * ((aa + _a24 * e) % _p)) % _p;
  }
  if (swap) {
    final tx = x2;
    x2 = x3;
    x3 = tx;
    final tz = z2;
    z2 = z3;
    z3 = tz;
  }
  return _encodeLE((x2 * z2.modPow(_p - BigInt.two, _p)) % _p);
}

bool _isSquare(BigInt v) {
  final e = v.modPow((_p - BigInt.one) >> 1, _p);
  return e == BigInt.zero || e == BigInt.one;
}

BigInt _curveRhs(BigInt x) => (((x * x + _curveA * x + BigInt.one) % _p) * x) % _p;

/// Elligator 2 for Curve25519 (RFC 9380, section 6.7.1, Z = 2): maps a field
/// element to the u-coordinate of a curve point whose discrete log nobody
/// knows.
BigInt _mapToCurve(BigInt r) {
  final denom = (BigInt.one + BigInt.two * r * r) % _p;
  final minusA = (_p - _curveA) % _p;
  final x1 = denom == BigInt.zero
      ? minusA
      : (minusA * denom.modPow(_p - BigInt.two, _p)) % _p;
  if (_isSquare(_curveRhs(x1))) return x1;
  return (minusA - x1) % _p;
}

/// True when [u] is the u-coordinate of a point on Curve25519 itself (not
/// its twist). Exposed for tests.
bool isOnCurve(List<int> u) => _isSquare(_curveRhs(_decodeLE(u) % _p));

const _generatorLabel = 'CloneStudio pairing v2 generator';
const _keyLabel = 'CloneStudio pairing v2 key';

/// The generator both sides derive from the PIN and the certificate
/// fingerprint of the TLS session they are talking over.
Uint8List pakeGenerator(String pin, List<int> fingerprint) {
  final pinBytes = utf8.encode(pin);
  final digest = crypto.sha512.convert([
    ...utf8.encode(_generatorLabel),
    pinBytes.length & 0xff,
    ...pinBytes,
    ...fingerprint,
  ]).bytes;
  return _encodeLE(_mapToCurve(_decodeLE(digest) % _p));
}

/// This side's public share for a fresh 32-byte [secret].
Uint8List pakeShare(List<int> secret, List<int> generator) =>
    x25519(secret, generator);

class PakeKeys {
  PakeKeys(this.clientConfirm, this.serverConfirm);

  /// Sent by the new computer, checked by the old one.
  final List<int> clientConfirm;

  /// Sent by the old computer, checked by the new one.
  final List<int> serverConfirm;
}

/// Derives the two confirmation values, or null when the peer's share is
/// malformed or a low-order point (which would make the shared secret
/// independent of the PIN).
PakeKeys? pakeKeys({
  required List<int> secret,
  required List<int> peerShare,
  required List<int> clientShare,
  required List<int> serverShare,
  required List<int> fingerprint,
}) {
  if (peerShare.length != 32 ||
      clientShare.length != 32 ||
      serverShare.length != 32) {
    return null;
  }
  final shared = x25519(secret, peerShare);
  var acc = 0;
  for (final b in shared) {
    acc |= b;
  }
  if (acc == 0) return null;
  final key = crypto.sha256.convert([
    ...utf8.encode(_keyLabel),
    ...shared,
    ...clientShare,
    ...serverShare,
    ...fingerprint,
  ]).bytes;
  final mac = crypto.Hmac(crypto.sha256, key);
  return PakeKeys(
    mac.convert(utf8.encode('client')).bytes,
    mac.convert(utf8.encode('server')).bytes,
  );
}
