import 'dart:io';

import 'package:clone_studio/core/discovery.dart';
import 'package:clone_studio/core/identity.dart';
import 'package:clone_studio/core/pairing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pairing succeeds with the right PIN and fails with a wrong one',
      () async {
    final identity = await Identity.load();
    final server = PairingServer(identity);
    await server.start();
    server.pin = '123456';

    final device = RemoteDevice(
        'test', 'Linux', InternetAddress.loopbackIPv4, server.port);

    // Wrong PIN is rejected.
    await expectLater(
      PairingClient.pair(device, '999999', myName: 'client'),
      throwsA(isA<PairingException>()),
    );
    expect(server.session, isNull);

    // Right PIN pairs and both sides know each other's names.
    final session =
        await PairingClient.pair(device, '123456', myName: 'client');
    expect(session.peerName, identity.deviceName);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.session, isNotNull);
    expect(server.session!.peerName, 'client');

    session.close();
    server.session?.close();
    server.stop();
  });
}
