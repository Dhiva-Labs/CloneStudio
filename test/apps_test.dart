import 'dart:convert';

import 'package:clone_studio/core/scanner.dart';
import 'package:flutter_test/flutter_test.dart';

ScanEntry app(String manager, String id) => ScanEntry(
      'apps',
      '',
      'Applications/x/$id',
      'app',
      0,
      0,
    )
      ..appManager = manager
      ..appId = id;

void main() {
  test('renderAppList builds reinstall files only for selected apps', () {
    final selected = [
      app('apt', 'firefox'),
      app('apt', 'vim'),
      app('flatpak', 'org.gimp.GIMP'),
      // no snaps selected
    ];
    final out = renderAppList(selected);
    final byName = {
      for (final e in out) e.relative.split('/').last: utf8.decode(e.content!)
    };

    expect(byName.containsKey('apt-manual.txt'), isTrue);
    expect(byName['apt-manual.txt'], 'firefox\nvim\n');
    expect(byName.containsKey('flatpak-apps.txt'), isTrue);
    expect(byName['flatpak-apps.txt'], 'org.gimp.GIMP\n');
    // No snaps selected -> no snap list file.
    expect(byName.containsKey('snap-list.txt'), isFalse);
    // Install script is always included when there is at least one app.
    expect(byName.containsKey('install_apps.sh'), isTrue);
    expect(byName['install_apps.sh']!.contains('apt-get install'), isTrue);
  });

  test('renderAppList is empty when nothing is selected', () {
    expect(renderAppList([]), isEmpty);
  });
}
