import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clone_studio/core/bundle.dart';
import 'package:clone_studio/core/discovery.dart';
import 'package:clone_studio/core/identity.dart';
import 'package:clone_studio/core/pairing.dart';
import 'package:clone_studio/core/scanner.dart';
import 'package:clone_studio/core/transfer.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

late Directory tmp;
late String src;
late String dst;

Future<void> makeSourceTree() async {
  src = '${tmp.path}/source';
  dst = '${tmp.path}/target';
  sourceRootOverride = src;
  targetRootOverride = dst;
  await Directory('$src/Desktop').create(recursive: true);
  await Directory('$src/Documents/sub dir').create(recursive: true);
  await Directory('$src/Pictures').create(recursive: true);
  await Directory('$src/.config/myapp/.cache').create(recursive: true);
  await Directory(dst).create(recursive: true);

  File('$src/Desktop/hello.txt').writeAsStringSync('hello from the old box');
  File("$src/Documents/sub dir/wei rd 'na\"me.txt")
      .writeAsStringSync('strange names survive');
  File('$src/Documents/empty.bin').writeAsBytesSync([]);
  final rng = Random(7);
  File('$src/Pictures/photo.bin').writeAsBytesSync(
      List.generate(1024 * 1024 + 137, (_) => rng.nextInt(256)));
  File('$src/Desktop/run.sh').writeAsStringSync('#!/bin/bash\necho hi\n');
  await Process.run('chmod', ['755', '$src/Desktop/run.sh']);
  await Link('$src/Documents/link-to-hello')
      .create('../Desktop/hello.txt');
  File('$src/.config/myapp/settings.ini').writeAsStringSync('theme=dark');
  File('$src/.config/myapp/.cache/junk.tmp')
      .writeAsStringSync('never migrate me');
}

String shaOf(String path) =>
    crypto.sha256.convert(File(path).readAsBytesSync()).toString();

Future<(Session, Session)> loopbackPair() async {
  final identity = await Identity.load();
  final server = PairingServer(identity);
  await server.start();
  server.pin = '123456';
  final client = await PairingClient.pair(
      RemoteDevice('old', 'Linux', InternetAddress.loopbackIPv4, server.port),
      '123456',
      myName: 'new');
  while (server.session == null) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  server.stop();
  return (server.session!, client);
}

void main() {
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('clone_studio_test');
    await makeSourceTree();
  });

  tearDown(() async {
    sourceRootOverride = null;
    targetRootOverride = null;
    await tmp.delete(recursive: true);
  });

  test('network transfer: integrity, permissions, symlinks, exclusions',
      () async {
    final (senderSide, receiverSide) = await loopbackPair();
    final sender = SenderController(senderSide, senderSide);
    final receiver = ReceiverController(receiverSide, receiverSide);
    final serving = sender.serve();

    expect(await receiver.requestScan(), isTrue);
    final desktop =
        receiver.categories.firstWhere((c) => c.id == 'desktop');
    expect(desktop.fileCount, 2);
    expect(desktop.available, isTrue);

    await receiver.start(['desktop', 'documents', 'pictures', 'dotfiles']);
    await serving;

    expect(receiver.state, TransferState.done);
    expect(receiver.failedFiles, 0);

    expect(shaOf('$dst/Desktop/hello.txt'), shaOf('$src/Desktop/hello.txt'));
    expect(shaOf('$dst/Pictures/photo.bin'), shaOf('$src/Pictures/photo.bin'));
    expect(shaOf("$dst/Documents/sub dir/wei rd 'na\"me.txt"),
        shaOf("$src/Documents/sub dir/wei rd 'na\"me.txt"));
    expect(File('$dst/Documents/empty.bin').lengthSync(), 0);

    // Executable bit survived.
    final stat = File('$dst/Desktop/run.sh').statSync();
    expect(stat.mode & 0x40, isNot(0)); // owner exec

    // Symlink survived as a symlink with the same target.
    expect(
        FileSystemEntity.typeSync('$dst/Documents/link-to-hello',
            followLinks: false),
        FileSystemEntityType.link);
    expect(Link('$dst/Documents/link-to-hello').targetSync(),
        '../Desktop/hello.txt');

    // Cache directories never travel.
    expect(File('$dst/.config/myapp/settings.ini').existsSync(), isTrue);
    expect(File('$dst/.config/myapp/.cache/junk.tmp').existsSync(), isFalse);

    // No half-written files left behind.
    final partials = Directory(dst)
        .listSync(recursive: true)
        .where((e) => e.path.endsWith('.partial'));
    expect(partials, isEmpty);

    senderSide.close();
    receiverSide.close();
  });

  test('interrupted transfer resumes from the journal', () async {
    // Round 1: cut the connection mid-transfer.
    final (senderSide1, receiverSide1) = await loopbackPair();
    final sender1 = SenderController(senderSide1, senderSide1);
    final receiver1 = ReceiverController(receiverSide1, receiverSide1);
    final serving1 = sender1.serve();
    await receiver1.requestScan();

    final started = receiver1.start(['desktop', 'documents', 'pictures']);
    while (receiver1.doneFiles < 2 &&
        receiver1.state != TransferState.done) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    receiverSide1.close();
    senderSide1.close();
    await started;
    await serving1;

    expect(receiver1.state, TransferState.error);
    final journal = File('$dst/.clone-studio/journal.json');
    expect(journal.existsSync(), isTrue);
    final doneCount =
        ((jsonDecode(journal.readAsStringSync()) as Map)['done'] as Map)
            .length;
    expect(doneCount, greaterThan(0));

    // Round 2: fresh pairing, same target — must skip what's journaled.
    final (senderSide2, receiverSide2) = await loopbackPair();
    final sender2 = SenderController(senderSide2, senderSide2);
    final receiver2 = ReceiverController(receiverSide2, receiverSide2);
    final serving2 = sender2.serve();
    await receiver2.requestScan();
    await receiver2.start(['desktop', 'documents', 'pictures']);
    await serving2;

    expect(receiver2.state, TransferState.done);
    expect(receiver2.skippedFiles, doneCount);
    expect(shaOf('$dst/Pictures/photo.bin'), shaOf('$src/Pictures/photo.bin'));
    expect(shaOf('$dst/Desktop/hello.txt'), shaOf('$src/Desktop/hello.txt'));

    senderSide2.close();
    receiverSide2.close();
  });

  test('pre-existing target files are kept, not overwritten', () async {
    await Directory('$dst/Desktop').create(recursive: true);
    File('$dst/Desktop/hello.txt')
        .writeAsStringSync('the new computer already had this');

    final (senderSide, receiverSide) = await loopbackPair();
    final sender = SenderController(senderSide, senderSide);
    final receiver = ReceiverController(receiverSide, receiverSide);
    final serving = sender.serve();
    await receiver.requestScan();
    await receiver.start(['desktop']);
    await serving;

    expect(receiver.state, TransferState.done);
    expect(File('$dst/Desktop/hello.txt').readAsStringSync(),
        'the new computer already had this');
    expect(
        File('$dst/Desktop/hello (from old computer).txt').readAsStringSync(),
        'hello from the old box');

    senderSide.close();
    receiverSide.close();
  });

  test('bundle export/import round-trips across split parts', () async {
    bundlePartLimit = 128 * 1024; // force several .csb parts

    final drive = '${tmp.path}/fake-usb';
    await Directory(drive).create(recursive: true);

    final writer = BundleWriter(drive);
    await writer.open();
    final exporter = SenderController(writer);
    await exporter.send(['desktop', 'documents', 'pictures'], []);
    await writer.writeManifest({
      'name': 'old-computer',
      'created': DateTime.now().toIso8601String(),
      'bytes': exporter.totalBytes,
      'files': exporter.totalFiles,
    });
    await writer.close();

    expect(exporter.state, TransferState.done);
    final parts = Directory('$drive/$bundleDirName')
        .listSync()
        .where((e) => e.path.endsWith('.csb'))
        .length;
    expect(parts, greaterThan(1));

    final manifest = BundleReader.readManifest(drive);
    expect(manifest?['name'], 'old-computer');

    final receiver = ReceiverController(BundleReader(drive));
    await receiver.importBundle();

    expect(receiver.state, TransferState.done);
    expect(receiver.failedFiles, 0);
    expect(shaOf('$dst/Pictures/photo.bin'), shaOf('$src/Pictures/photo.bin'));
    expect(shaOf('$dst/Desktop/hello.txt'), shaOf('$src/Desktop/hello.txt'));
    expect(Link('$dst/Documents/link-to-hello').targetSync(),
        '../Desktop/hello.txt');

    bundlePartLimit = 3758096384;
  });
}
