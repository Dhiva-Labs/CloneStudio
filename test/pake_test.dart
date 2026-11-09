import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clone_studio/core/discovery.dart';
import 'package:clone_studio/core/identity.dart';
import 'package:clone_studio/core/pairing.dart';
import 'package:clone_studio/core/pake.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> hex(String s) =>
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];
String toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
List<int> rand32() {
  final r = Random.secure();
  return List.generate(32, (_) => r.nextInt(256));
}

void main() {
  group('x25519 (RFC 7748 vectors)', () {
    test('section 5.2 vector 1', () {
      expect(
        toHex(x25519(
          hex('a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4'),
          hex('e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c'),
        )),
        'c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552',
      );
    });
    test('section 5.2 vector 2', () {
      expect(
        toHex(x25519(
          hex('4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d'),
          hex('e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493'),
        )),
        '95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957',
      );
    });
    test('section 6.1 Diffie-Hellman', () {
      final base = [9, ...List.filled(31, 0)];
      final a = hex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
      final b = hex('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb');
      final pa = x25519(a, base), pb = x25519(b, base);
      expect(toHex(pa),
          '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a');
      expect(toHex(pb),
          'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f');
      expect(toHex(x25519(a, pb)),
          '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742');
      expect(toHex(x25519(b, pa)), toHex(x25519(a, pb)));
    });
  });

  group('pake', () {
    final fp = List.generate(32, (i) => i);

    test('the generator is a curve point that depends on PIN and channel', () {
      final seen = <String>{};
      for (final pin in ['000000', '000001', '123456', '999999']) {
        final g = pakeGenerator(pin, fp);
        expect(isOnCurve(g), isTrue, reason: pin);
        expect(seen.add(toHex(g)), isTrue, reason: 'distinct for $pin');
      }
      expect(toHex(pakeGenerator('123456', List.filled(32, 7))),
          isNot(toHex(pakeGenerator('123456', fp))));
      expect(toHex(pakeGenerator('123456', fp)), toHex(pakeGenerator('123456', fp)));
    });

    test('matching PINs agree, a wrong PIN or another channel does not', () {
      PakeKeys? run(String clientPin, String serverPin, List<int> clientFp) {
        final cs = rand32(), ss = rand32();
        final c = pakeShare(cs, pakeGenerator(clientPin, clientFp));
        final s = pakeShare(ss, pakeGenerator(serverPin, fp));
        final ck = pakeKeys(
            secret: cs, peerShare: s, clientShare: c, serverShare: s, fingerprint: clientFp);
        final sk = pakeKeys(
            secret: ss, peerShare: c, clientShare: c, serverShare: s, fingerprint: fp);
        // Hand back what each side would compare against the other's value.
        return PakeKeys(ck!.clientConfirm, sk!.clientConfirm);
      }

      final ok = run('123456', '123456', fp);
      expect(ok!.clientConfirm, ok.serverConfirm);
      final wrongPin = run('123457', '123456', fp);
      expect(wrongPin!.clientConfirm, isNot(wrongPin.serverConfirm));
      // Same PIN, but the client saw a different certificate: a relay
      // through a man-in-the-middle's TLS sessions.
      final mitm = run('123456', '123456', List.filled(32, 9));
      expect(mitm!.clientConfirm, isNot(mitm.serverConfirm));
    });

    test('low-order and malformed shares are refused', () {
      final s = rand32();
      final good = pakeShare(rand32(), pakeGenerator('123456', fp));
      PakeKeys? k(List<int> peer) => pakeKeys(
          secret: s, peerShare: peer, clientShare: good, serverShare: good, fingerprint: fp);
      expect(k(List.filled(32, 0)), isNull); // u = 0
      expect(k([1, ...List.filled(31, 0)]), isNull); // u = 1
      expect(k([1, 2, 3]), isNull);
      expect(k(good), isNotNull);
    });
  });

  group('pairing against hostile peers', () {
    late Identity identity;
    setUp(() async => identity = await Identity.load());

    Future<SecureServerSocket> rogue(
        Future<void> Function(Session s, Map<String, dynamic> hello) script) async {
      final server = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4, 0, identity.context);
      server.listen((socket) async {
        final s = Session(socket);
        try {
          final hello = await s.readJson();
          if (hello != null) await script(s, hello);
          await socket.flush();
        } catch (_) {}
        s.close();
      });
      return server;
    }

    RemoteDevice at(int port) =>
        RemoteDevice('rogue', 'Linux', InternetAddress.loopbackIPv4, port);

    test('a peer that just says "ok" is not trusted', () async {
      final server = await rogue((s, _) async => s.sendJson({'type': 'ok', 'name': 'old'}));
      await expectLater(PairingClient.pair(at(server.port), '123456', myName: 'c'),
          throwsA(isA<PairingException>()));
      await server.close();
    });

    test('a peer that does not know the PIN cannot fake the proof', () async {
      final server = await rogue((s, hello) async {
        // Plays the protocol honestly, with a guessed PIN.
        final secret = rand32();
        final share = pakeShare(secret, pakeGenerator('654321', identity.fingerprint));
        final client = base64Decode(hello['share'] as String);
        final keys = pakeKeys(
            secret: secret,
            peerShare: client,
            clientShare: client,
            serverShare: share,
            fingerprint: identity.fingerprint)!;
        s.sendJson({
          'type': 'pake',
          'share': base64Encode(share),
          'confirm': base64Encode(keys.serverConfirm),
        });
        final reply = await s.readJson();
        // The client must hang up without sending its own confirmation.
        expect(reply, isNull);
      });
      await expectLater(PairingClient.pair(at(server.port), '123456', myName: 'c'),
          throwsA(isA<PairingException>()));
      await server.close();
    });

    test('an old-protocol peer gets a clear "update" message', () async {
      final server = await rogue((s, _) async =>
          s.sendJson({'type': 'challenge', 'nonce': 'AAAA', 'salt': 'AAAA'}));
      await expectLater(
          PairingClient.pair(at(server.port), '123456', myName: 'c'),
          throwsA(isA<PairingException>().having(
              (e) => e.friendly, 'friendly', contains('different versions'))));
      await server.close();
    });

    test('abandoned exchanges still spend guesses and rotate the PIN', () async {
      final server = PairingServer(identity);
      await server.start();
      server.pin = '123456';
      for (var i = 0; i < 3; i++) {
        final socket = await SecureSocket.connect(
            InternetAddress.loopbackIPv4, server.port,
            onBadCertificate: (_) => true);
        final s = Session(socket);
        s.sendJson({
          'type': 'hello',
          'v': pairingVersion,
          'name': 'x',
          'share': base64Encode(
              pakeShare(rand32(), pakeGenerator('00000$i', identity.fingerprint))),
        });
        final reply = await s.readJson();
        expect(reply!['type'], 'pake');
        s.close(); // never confirm
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.pin, isNot('123456'),
          reason: 'three unanswered exchanges are three guesses');
      expect(server.session, isNull);
      server.stop();
    });

    test('a version 1 hello is told to upgrade', () async {
      final server = PairingServer(identity);
      await server.start();
      final socket = await SecureSocket.connect(
          InternetAddress.loopbackIPv4, server.port,
          onBadCertificate: (_) => true);
      final s = Session(socket);
      s.sendJson({'type': 'hello', 'name': 'old client'});
      expect((await s.readJson())!['type'], 'upgrade');
      s.close();
      server.stop();
    });
  });
}
