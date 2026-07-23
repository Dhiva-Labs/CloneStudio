import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clone_studio/core/bundle.dart';
import 'package:clone_studio/core/discovery.dart';
import 'package:clone_studio/core/identity.dart';
import 'package:clone_studio/core/pairing.dart';
import 'package:clone_studio/core/scanner.dart';
import 'package:clone_studio/core/transfer.dart';
import 'package:clone_studio/models/selection.dart';
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
  File('$src/Pictures/small.bin').writeAsBytesSync([1, 2, 3, 4, 5]);
  File('$src/Desktop/run.sh').writeAsStringSync('#!/bin/bash\necho hi\n');
  await Process.run('chmod', ['755', '$src/Desktop/run.sh']);
  await Link('$src/Documents/link-to-hello').create('../Desktop/hello.txt');
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

/// The source's selection = every scanned leaf in the given categories.
Set<String> pick(ScanResult scan, Set<String> cats) => {
      for (final e in scan.leaves)
        if (cats.contains(e.categoryId)) e.relative,
    };

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

  test('offer/review network transfer: integrity, perms, symlinks, exclusions',
      () async {
    final scan = await scanEverything();
    final selection = pick(scan, {'desktop', 'documents', 'pictures', 'dotfiles'});

    final (sSide, rSide) = await loopbackPair();
    final sender = SenderController(sSide, sSide)..setPlan(scan, selection);
    final receiver = ReceiverController(rSide, rSide);

    final serving = sender.serve();
    expect(await receiver.receiveOffer(), isTrue);
    // The new computer accepts the whole offer.
    final include = {for (final l in receiver.offerLeaves) l.rel};
    await receiver.startReceive(include);
    await serving;

    expect(receiver.state, TransferState.done);
    expect(receiver.failedFiles, 0);

    expect(shaOf('$dst/Desktop/hello.txt'), shaOf('$src/Desktop/hello.txt'));
    expect(shaOf('$dst/Pictures/photo.bin'), shaOf('$src/Pictures/photo.bin'));
    expect(shaOf("$dst/Documents/sub dir/wei rd 'na\"me.txt"),
        shaOf("$src/Documents/sub dir/wei rd 'na\"me.txt"));
    expect(File('$dst/Documents/empty.bin').lengthSync(), 0);

    final stat = File('$dst/Desktop/run.sh').statSync();
    expect(stat.mode & 0x40, isNot(0)); // owner exec preserved

    expect(
        FileSystemEntity.typeSync('$dst/Documents/link-to-hello',
            followLinks: false),
        FileSystemEntityType.link);

    expect(File('$dst/.config/myapp/settings.ini').existsSync(), isTrue);
    expect(File('$dst/.config/myapp/.cache/junk.tmp').existsSync(), isFalse);

    final partials = Directory(dst)
        .listSync(recursive: true)
        .where((e) => e.path.endsWith('.partial'));
    expect(partials, isEmpty);

    sSide.close();
    rSide.close();
  });

  test('new computer trims the offer — unticked files never arrive', () async {
    final scan = await scanEverything();
    final selection = pick(scan, {'desktop', 'pictures'});

    final (sSide, rSide) = await loopbackPair();
    final sender = SenderController(sSide, sSide)..setPlan(scan, selection);
    final receiver = ReceiverController(rSide, rSide);

    final serving = sender.serve();
    expect(await receiver.receiveOffer(), isTrue);
    // Drop the big photo from the incoming set.
    final include = {
      for (final l in receiver.offerLeaves)
        if (!l.rel.endsWith('photo.bin')) l.rel
    };
    await receiver.startReceive(include);
    await serving;

    expect(receiver.state, TransferState.done);
    expect(File('$dst/Desktop/hello.txt').existsSync(), isTrue);
    expect(File('$dst/Pictures/small.bin').existsSync(), isTrue);
    expect(File('$dst/Pictures/photo.bin').existsSync(), isFalse);

    sSide.close();
    rSide.close();
  });

  test('interrupted transfer resumes from the journal', () async {
    final scan = await scanEverything();
    final selection = pick(scan, {'desktop', 'documents', 'pictures'});

    // Round 1: cut the connection mid-transfer.
    final (s1, r1) = await loopbackPair();
    final sender1 = SenderController(s1, s1)..setPlan(scan, selection);
    final receiver1 = ReceiverController(r1, r1);
    final serving1 = sender1.serve();
    await receiver1.receiveOffer();
    final include1 = {for (final l in receiver1.offerLeaves) l.rel};
    final started = receiver1.startReceive(include1);
    while (receiver1.doneFiles < 2 && receiver1.state != TransferState.done) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    r1.close();
    s1.close();
    await started;
    await serving1;

    expect(receiver1.state, TransferState.error);
    final journal = File('$dst/.clone-studio/journal.json');
    final doneCount =
        ((jsonDecode(journal.readAsStringSync()) as Map)['done'] as Map).length;
    expect(doneCount, greaterThan(0));

    // Round 2: fresh pairing, same target — skip what's journaled.
    final (s2, r2) = await loopbackPair();
    final sender2 = SenderController(s2, s2)..setPlan(scan, selection);
    final receiver2 = ReceiverController(r2, r2);
    final serving2 = sender2.serve();
    await receiver2.receiveOffer();
    final include2 = {for (final l in receiver2.offerLeaves) l.rel};
    await receiver2.startReceive(include2);
    await serving2;

    expect(receiver2.state, TransferState.done);
    expect(receiver2.skippedFiles, doneCount);
    expect(shaOf('$dst/Pictures/photo.bin'), shaOf('$src/Pictures/photo.bin'));

    s2.close();
    r2.close();
  });

  test('pre-existing target files are kept, not overwritten', () async {
    await Directory('$dst/Desktop').create(recursive: true);
    File('$dst/Desktop/hello.txt')
        .writeAsStringSync('the new computer already had this');

    final scan = await scanEverything();
    final selection = pick(scan, {'desktop'});

    final (sSide, rSide) = await loopbackPair();
    final sender = SenderController(sSide, sSide)..setPlan(scan, selection);
    final receiver = ReceiverController(rSide, rSide);
    final serving = sender.serve();
    await receiver.receiveOffer();
    await receiver.startReceive({for (final l in receiver.offerLeaves) l.rel});
    await serving;

    expect(receiver.state, TransferState.done);
    expect(File('$dst/Desktop/hello.txt').readAsStringSync(),
        'the new computer already had this');
    expect(
        File('$dst/Desktop/hello (from old computer).txt').readAsStringSync(),
        'hello from the old box');

    sSide.close();
    rSide.close();
  });

  test('bundle export/import round-trips and honours import-time trimming',
      () async {
    bundlePartLimit = 128 * 1024; // force several .csb parts

    final drive = '${tmp.path}/fake-usb';
    await Directory(drive).create(recursive: true);

    final scan = await scanEverything();
    final selection = pick(scan, {'desktop', 'documents', 'pictures'});

    final writer = BundleWriter(drive);
    await writer.open();
    final exporter = SenderController(writer)..setPlan(scan, selection);
    await exporter.exportBundle();
    final leavesWire = [
      for (final e in scan.leaves)
        if (selection.contains(e.relative))
          Leaf(e.relative, e.size, e.kind, e.categoryId).toWire(),
    ];
    await writer.writeManifest({
      'name': 'old-computer',
      'bytes': exporter.totalBytes,
      'files': exporter.totalFiles,
      'cats': [
        for (final c in scan.categories)
          if (c.available)
            {'id': c.id, 'name': c.name, 'icon': c.icon, 'settings': c.settings}
      ],
      'leaves': leavesWire,
    });
    await writer.close();
    expect(exporter.state, TransferState.done);
    expect(
        Directory('$drive/$bundleDirName')
            .listSync()
            .where((e) => e.path.endsWith('.csb'))
            .length,
        greaterThan(1));

    final manifest = BundleReader.readManifest(drive)!;
    final leaves = [
      for (final l in (manifest['leaves'] as List).cast<Map<String, dynamic>>())
        Leaf.fromWire(l)
    ];
    // Import everything except the big photo.
    final include = {
      for (final l in leaves)
        if (!l.rel.endsWith('photo.bin')) l.rel
    };

    final receiver = ReceiverController(BundleReader(drive));
    await receiver.importBundle(include, leaves, peer: 'old-computer');

    expect(receiver.state, TransferState.done);
    expect(receiver.failedFiles, 0);
    expect(File('$dst/Desktop/hello.txt').existsSync(), isTrue);
    expect(shaOf('$dst/Pictures/small.bin'), shaOf('$src/Pictures/small.bin'));
    expect(File('$dst/Pictures/photo.bin').existsSync(), isFalse);
    expect(Link('$dst/Documents/link-to-hello').targetSync(),
        '../Desktop/hello.txt');

    bundlePartLimit = 3758096384;
  });
}
