import 'dart:convert';
import 'dart:io';

/// What the source computer offers for migration. Real paths and real
/// sizes — this is the truth behind the category cards.
///
/// `CLONE_STUDIO_SOURCE_ROOT` overrides the scanned root (used by tests and
/// same-machine demos so the real home directory isn't shipped around).
class ScanCategory {
  ScanCategory({
    required this.id,
    required this.name,
    required this.icon,
    this.paths = const [],
    this.settings = false,
    this.virtual = false,
  });

  final String id;
  final String name;
  final String icon;
  final List<String> paths; // absolute, on the source machine
  final bool settings; // only ticked in Recommended mode, not Safe
  final bool virtual; // produced by a command, not copied from disk

  int sizeBytes = 0;
  int fileCount = 0;
  bool available = true;
  String? note;

  Map<String, dynamic> toWire() => {
        'id': id,
        'name': name,
        'icon': icon,
        'settings': settings,
        'size': sizeBytes,
        'files': fileCount,
        'available': available,
        if (note != null) 'note': note,
      };
}

/// Test hooks — production code always goes through the env/HOME chain.
String? sourceRootOverride;
String? targetRootOverride;

String sourceRoot() =>
    sourceRootOverride ??
    Platform.environment['CLONE_STUDIO_SOURCE_ROOT'] ??
    Platform.environment['HOME'] ??
    '/';

String targetRoot() =>
    targetRootOverride ??
    Platform.environment['CLONE_STUDIO_TARGET_ROOT'] ??
    Platform.environment['HOME'] ??
    '/';

/// Directory names never worth migrating.
const _excluded = {
  '.cache', 'Cache', 'CachedData', 'node_modules', '.npm', '.pub-cache',
  '.gradle', '.dartServer', 'Trash', '.venv', 'venv', '__pycache__',
};

List<ScanCategory> buildCategories() {
  final r = sourceRoot();
  return [
    ScanCategory(
        id: 'apps', name: 'Applications', icon: '📦', virtual: true),
    ScanCategory(
        id: 'desktop', name: 'Desktop', icon: '🖥️', paths: ['$r/Desktop']),
    ScanCategory(
        id: 'documents',
        name: 'Documents',
        icon: '📄',
        paths: ['$r/Documents']),
    ScanCategory(
        id: 'downloads',
        name: 'Downloads',
        icon: '📥',
        paths: ['$r/Downloads']),
    ScanCategory(
        id: 'pictures', name: 'Pictures', icon: '🖼️', paths: ['$r/Pictures']),
    ScanCategory(
        id: 'videos', name: 'Videos', icon: '🎬', paths: ['$r/Videos']),
    ScanCategory(id: 'music', name: 'Music', icon: '🎵', paths: ['$r/Music']),
    ScanCategory(
      id: 'dotfiles',
      name: 'App settings & dotfiles',
      icon: '⚙️',
      settings: true,
      paths: [
        '$r/.config',
        '$r/.local/share',
        '$r/.bashrc',
        '$r/.zshrc',
        '$r/.profile',
        '$r/.gitconfig',
        '$r/.vimrc',
      ],
    ),
    ScanCategory(
        id: 'ssh',
        name: 'SSH keys',
        icon: '🔑',
        settings: true,
        paths: ['$r/.ssh']),
    ScanCategory(
      id: 'browsers',
      name: 'Browser profiles',
      icon: '🌐',
      settings: true,
      paths: [
        '$r/.mozilla',
        '$r/.config/google-chrome',
        '$r/.config/chromium',
        '$r/.config/BraveSoftware',
      ],
    ),
    ScanCategory(
        id: 'desktop-settings',
        name: 'Desktop look & feel',
        icon: '🎨',
        settings: true,
        virtual: true),
    ScanCategory(
        id: 'cron',
        name: 'Scheduled tasks',
        icon: '⏰',
        settings: true,
        virtual: true),
  ];
}

/// One migratable item found on disk.
class ScanEntry {
  ScanEntry(this.categoryId, this.absolute, this.relative, this.kind,
      this.size, this.mode);
  final String categoryId;
  final String absolute; // source path (or inline content for virtual)
  final String relative; // path under the target root
  final String kind; // file | dir | symlink | virtual
  final int size;
  final int mode; // unix permission bits
  String? linkTarget;
  List<int>? content; // virtual entries carry their bytes directly
}

bool _isExcluded(String name) => _excluded.contains(name);

/// Walks one category and returns its entries. Never follows symlinks.
Future<List<ScanEntry>> scanCategory(ScanCategory c) async {
  final entries = <ScanEntry>[];
  final root = sourceRoot();

  if (c.virtual) {
    for (final v in await _virtualEntries(c)) {
      entries.add(v);
    }
    return entries;
  }

  for (final p in c.paths) {
    final type = FileSystemEntity.typeSync(p, followLinks: false);
    if (type == FileSystemEntityType.notFound) continue;
    final rel = p.startsWith('$root/') ? p.substring(root.length + 1) : p;
    if (type == FileSystemEntityType.file) {
      final st = File(p).statSync();
      entries.add(ScanEntry(
          c.id, p, rel, 'file', st.size, st.mode & 0xFFF));
    } else if (type == FileSystemEntityType.directory) {
      await _walk(c.id, Directory(p), root, entries);
    }
  }
  return entries;
}

Future<void> _walk(String catId, Directory dir, String root,
    List<ScanEntry> out) async {
  final rel = dir.path.startsWith('$root/')
      ? dir.path.substring(root.length + 1)
      : dir.path;
  final st = dir.statSync();
  out.add(ScanEntry(catId, dir.path, rel, 'dir', 0, st.mode & 0xFFF));

  List<FileSystemEntity> children;
  try {
    children = dir.listSync(followLinks: false);
  } catch (_) {
    return; // unreadable directory — skip quietly
  }
  for (final e in children) {
    final name = e.path.split('/').last;
    if (_isExcluded(name)) continue;
    final type = FileSystemEntity.typeSync(e.path, followLinks: false);
    final childRel = e.path.substring(root.length + 1);
    if (type == FileSystemEntityType.link) {
      String target;
      try {
        target = Link(e.path).targetSync();
      } catch (_) {
        continue;
      }
      out.add(ScanEntry(catId, e.path, childRel, 'symlink', 0, 0)
        ..linkTarget = target);
    } else if (type == FileSystemEntityType.directory) {
      await _walk(catId, Directory(e.path), root, out);
    } else if (type == FileSystemEntityType.file) {
      FileStat st;
      try {
        st = File(e.path).statSync();
      } catch (_) {
        continue;
      }
      out.add(ScanEntry(
          catId, e.path, childRel, 'file', st.size, st.mode & 0xFFF));
    }
  }
}

/// Virtual categories: content generated by commands on the source machine,
/// restored as files under CloneStudio-Restore/ on the target.
Future<List<ScanEntry>> _virtualEntries(ScanCategory c) async {
  final out = <ScanEntry>[];

  Future<void> add(String rel, String content) async {
    final bytes = utf8.encode(content);
    out.add(ScanEntry(c.id, '', rel, 'virtual', bytes.length, 420)
      ..content = bytes);
  }

  Future<String?> run(String cmd, List<String> args) async {
    try {
      final res = await Process.run(cmd, args);
      if (res.exitCode == 0) return res.stdout as String;
    } catch (_) {}
    return null;
  }

  switch (c.id) {
    case 'apps':
      final apt = await run('apt-mark', ['showmanual']);
      if (apt != null && apt.trim().isNotEmpty) {
        await add('CloneStudio-Restore/packages/apt-manual.txt', apt);
      }
      final flatpak =
          await run('flatpak', ['list', '--app', '--columns=application']);
      if (flatpak != null && flatpak.trim().isNotEmpty) {
        await add('CloneStudio-Restore/packages/flatpak-apps.txt', flatpak);
      }
      final snap = await run('snap', ['list']);
      if (snap != null && snap.trim().isNotEmpty) {
        await add('CloneStudio-Restore/packages/snap-list.txt', snap);
      }
      if (out.isNotEmpty) {
        await add('CloneStudio-Restore/packages/install_apps.sh',
            _installScript());
      }
    case 'desktop-settings':
      final dconf = await run('dconf', ['dump', '/']);
      if (dconf != null && dconf.trim().isNotEmpty) {
        await add('CloneStudio-Restore/settings/dconf-settings.ini', dconf);
      }
    case 'cron':
      final cron = await run('crontab', ['-l']);
      if (cron != null && cron.trim().isNotEmpty) {
        await add('CloneStudio-Restore/settings/crontab.txt', cron);
      }
  }
  return out;
}

String _installScript() => '''
#!/bin/bash
# Generated by Clone Studio — reinstalls the apps from your old computer.
# Run with:  bash install_apps.sh
set -e
HERE="\$(dirname "\$0")"
if [ -f "\$HERE/apt-manual.txt" ] && command -v apt-get >/dev/null; then
  echo "Installing apt packages (already-installed ones are skipped)..."
  xargs -a "\$HERE/apt-manual.txt" sudo apt-get install -y --ignore-missing || true
fi
if [ -f "\$HERE/flatpak-apps.txt" ] && command -v flatpak >/dev/null; then
  echo "Installing flatpak apps..."
  xargs -a "\$HERE/flatpak-apps.txt" -n1 flatpak install -y --noninteractive || true
fi
echo "Done. Snap apps are listed in snap-list.txt — install the ones you use with: sudo snap install <name>"
''';

/// Sizes every category (entry counts + byte totals). Reasonably fast:
/// it walks the tree once per category.
Future<List<ScanCategory>> scanAll() async {
  final cats = buildCategories();
  for (final c in cats) {
    final entries = await scanCategory(c);
    c.fileCount = entries.where((e) => e.kind != 'dir').length;
    c.sizeBytes = entries.fold(0, (s, e) => s + e.size);
    if (c.fileCount == 0) {
      c.available = false;
      c.note = 'Nothing found here';
    }
    if (c.id == 'apps' && c.fileCount > 0) {
      // Show the package count, not the size of the text files.
      final aptEntry = entries
          .where((e) => e.relative.endsWith('apt-manual.txt'))
          .toList();
      if (aptEntry.isNotEmpty && aptEntry.first.content != null) {
        final count = utf8
            .decode(aptEntry.first.content!)
            .trim()
            .split('\n')
            .length;
        c.note = '$count apps';
      }
    }
  }
  return cats;
}

/// Free bytes on the filesystem holding [path].
Future<int> freeBytes(String path) async {
  try {
    final res = await Process.run('df', ['-B1', '--output=avail', path]);
    if (res.exitCode == 0) {
      final lines = (res.stdout as String).trim().split('\n');
      return int.parse(lines.last.trim());
    }
  } catch (_) {}
  return 1 << 50; // if df is unavailable, don't block the user
}
