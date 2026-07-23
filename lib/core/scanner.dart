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
  final String kind; // file | dir | symlink | virtual | app
  final int size;
  final int mode; // unix permission bits
  String? linkTarget;
  List<int>? content; // virtual entries carry their bytes directly

  // For kind 'app' — an installed application picked as a whole, reinstalled
  // from a list on the new computer rather than copied file-by-file.
  String? appManager; // apt | flatpak | snap
  String? appId; // package name / application id
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

  ScanEntry appEntry(String manager, String label, String id) => ScanEntry(
        c.id,
        '',
        'Applications/$label/$id',
        'app',
        0,
        0,
      )
        ..appManager = manager
        ..appId = id;

  switch (c.id) {
    case 'apps':
      // Each installed app is its own tickable item; the reinstall list is
      // generated from whatever the user selects (see renderAppList).
      final apt = await run('apt-mark', ['showmanual']);
      if (apt != null) {
        for (final line in apt.trim().split('\n')) {
          final id = line.trim();
          if (id.isNotEmpty) out.add(appEntry('apt', 'Apt packages', id));
        }
      }
      final flatpak =
          await run('flatpak', ['list', '--app', '--columns=application']);
      if (flatpak != null) {
        for (final line in flatpak.trim().split('\n')) {
          final id = line.trim();
          if (id.isNotEmpty) out.add(appEntry('flatpak', 'Flatpak apps', id));
        }
      }
      final snap = await run('snap', ['list']);
      if (snap != null) {
        final lines = snap.trim().split('\n');
        for (var i = 1; i < lines.length; i++) {
          // "snap list" is a table; the first column is the snap name.
          final name = lines[i].split(RegExp(r'\s+')).first.trim();
          if (name.isNotEmpty) out.add(appEntry('snap', 'Snap apps', name));
        }
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

/// Turns the user's selected app entries into the reinstall files that ship
/// under CloneStudio-Restore/packages/. Called at send time so the list
/// reflects exactly what was ticked.
List<ScanEntry> renderAppList(Iterable<ScanEntry> selectedApps) {
  final apt = <String>[], flatpak = <String>[], snap = <String>[];
  for (final a in selectedApps) {
    final id = a.appId;
    if (id == null) continue;
    switch (a.appManager) {
      case 'apt':
        apt.add(id);
      case 'flatpak':
        flatpak.add(id);
      case 'snap':
        snap.add(id);
    }
  }

  final out = <ScanEntry>[];
  void add(String rel, String content) {
    final bytes = utf8.encode(content);
    out.add(ScanEntry('apps', '', rel, 'virtual', bytes.length, 420)
      ..content = bytes);
  }

  const base = 'CloneStudio-Restore/packages';
  if (apt.isNotEmpty) add('$base/apt-manual.txt', '${apt.join('\n')}\n');
  if (flatpak.isNotEmpty) {
    add('$base/flatpak-apps.txt', '${flatpak.join('\n')}\n');
  }
  if (snap.isNotEmpty) add('$base/snap-list.txt', '${snap.join('\n')}\n');
  if (out.isNotEmpty) add('$base/install_apps.sh', _installScript());
  return out;
}

/// A full source scan: categories sized up, plus every entry (dirs, files,
/// symlinks, virtual) in walk order so the transfer engine and the file
/// tree both work from one pass.
class ScanResult {
  ScanResult(this.categories, this.entries);
  final List<ScanCategory> categories;
  final List<ScanEntry> entries;

  /// The selectable leaves (no directories) — what the file tree is built
  /// from and what gets offered to the other computer.
  List<ScanEntry> get leaves =>
      [for (final e in entries) if (e.kind != 'dir') e];
}

Future<ScanResult> scanEverything() async {
  final cats = buildCategories();
  final all = <ScanEntry>[];
  for (final c in cats) {
    final entries = await scanCategory(c);
    c.fileCount = entries.where((e) => e.kind != 'dir').length;
    c.sizeBytes = entries.fold(0, (s, e) => s + e.size);
    if (c.fileCount == 0) {
      c.available = false;
      c.note = 'Nothing found here';
    }
    if (c.id == 'apps') {
      final count = entries.where((e) => e.kind == 'app').length;
      c.available = count > 0;
      c.note = count > 0 ? '$count apps' : 'Nothing found here';
    }
    all.addAll(entries);
  }
  return ScanResult(cats, all);
}

/// Sizes every category (entry counts + byte totals).
Future<List<ScanCategory>> scanAll() async => (await scanEverything()).categories;

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
