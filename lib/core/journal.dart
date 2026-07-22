import 'dart:convert';
import 'dart:io';

/// The fail-safe ledger on the target computer. A file is listed here only
/// after it was fully written, verified and renamed into place — so resuming
/// means "send everything not in the journal".
class Journal {
  Journal._(this._file, this.done);

  final File _file;

  /// relative path -> {"s": size, "sha": hex}
  final Map<String, dynamic> done;

  int _unsaved = 0;

  static Future<Journal> open(String targetRoot) async {
    final file = File('$targetRoot/.clone-studio/journal.json');
    Map<String, dynamic> done = {};
    if (file.existsSync()) {
      try {
        done = (jsonDecode(await file.readAsString())
                as Map<String, dynamic>)['done'] as Map<String, dynamic>? ??
            {};
      } catch (_) {} // corrupt journal — start over, worst case we re-copy
    }
    return Journal._(file, done);
  }

  bool has(String rel, int size) {
    final e = done[rel];
    return e is Map && e['s'] == size;
  }

  Future<void> add(String rel, int size, String sha) async {
    done[rel] = {'s': size, 'sha': sha};
    _unsaved++;
    if (_unsaved >= 25) await save();
  }

  Future<void> save() async {
    _unsaved = 0;
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    final raf = await tmp.open(mode: FileMode.write);
    await raf.writeString(jsonEncode({'done': done}));
    await raf.flush(); // survive power loss between write and rename
    await raf.close();
    await tmp.rename(_file.path);
  }

  /// Wire form of what we already have, so the sender can skip it.
  /// Entries whose file has since vanished are dropped — they must be re-sent.
  List<Map<String, dynamic>> toHave(String root) => [
        for (final e in done.entries)
          if (File('$root/${e.key}').existsSync() &&
              File('$root/${e.key}').lengthSync() == (e.value as Map)['s'])
            {'p': e.key, 's': (e.value as Map)['s']},
      ];

  Future<void> clear() async {
    done.clear();
    if (_file.existsSync()) await _file.delete();
  }
}
