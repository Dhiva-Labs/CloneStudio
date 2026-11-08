import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'scanner.dart' show installScript;

/// Checks applied to everything the receiving side writes. The other
/// computer (or a bundle found on a USB stick) chooses every path and byte
/// that arrives, and the old computer is exactly the machine most likely to
/// be compromised, so nothing it sends is trusted to land where it says.

/// The absolute destination for the peer-supplied relative path [rel]
/// under [root], or null when it would escape the root: absolute paths,
/// `..` or empty components, NUL bytes, and any existing ancestor that is a
/// symbolic link (a link planted earlier in the same transfer would
/// otherwise redirect later writes anywhere the user can write).
String? safeDest(String root, String rel) {
  if (rel.isEmpty || rel.startsWith('/') || rel.contains('\u0000')) {
    return null;
  }
  final parts = rel.split('/');
  for (final part in parts) {
    if (part.isEmpty || part == '.' || part == '..') return null;
  }
  var prefix = root;
  for (var i = 0; i < parts.length - 1; i++) {
    prefix = '$prefix/${parts[i]}';
    if (FileSystemEntity.typeSync(prefix, followLinks: false) ==
        FileSystemEntityType.link) {
      return null;
    }
  }
  return '$root/$rel';
}

/// True when [path] itself currently exists as a symbolic link.
bool isLink(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) ==
    FileSystemEntityType.link;

const restorePackagesDir = 'CloneStudio-Restore/packages';

final _aptName = RegExp(r'^[a-z0-9][a-z0-9.+-]+(:[a-z0-9-]+)?$');
final _flatpakRef = RegExp(
  r'^[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_.-]*){0,2}$',
);
final _snapName = RegExp(r'^[a-z0-9][a-z0-9-]*$');

/// Replacement content for a file under [restorePackagesDir], or null when
/// [rel] is not one of the files the installer reads. The install script is
/// never taken from the peer: it is regenerated from this build's template.
/// Package lists keep only lines that are valid names for their manager, so
/// nothing that reaches `apt-get install` or `flatpak install` can be an
/// option flag or a shell fragment.
Uint8List? sanitizeRestoreFile(String rel, List<int> received) {
  if (!rel.startsWith('$restorePackagesDir/')) return null;
  final name = rel.substring(restorePackagesDir.length + 1);
  switch (name) {
    case 'install_apps.sh':
      return Uint8List.fromList(utf8.encode(installScript()));
    case 'apt-manual.txt':
      return _filterLines(received, _aptName);
    case 'flatpak-apps.txt':
      return _filterLines(received, _flatpakRef);
    case 'snap-list.txt':
      return _filterLines(received, _snapName);
  }
  return null;
}

Uint8List _filterLines(List<int> received, RegExp ok) {
  final text = utf8.decode(received, allowMalformed: true);
  final kept = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && ok.hasMatch(l));
  final out = kept.isEmpty ? '' : '${kept.join('\n')}\n';
  return Uint8List.fromList(utf8.encode(out));
}
