import 'package:clone_studio/core/scanner.dart';
import 'package:clone_studio/models/selection.dart';
import 'package:flutter_test/flutter_test.dart';

ScanCategory cat(String id, {bool settings = false}) =>
    ScanCategory(id: id, name: id, icon: '📁', settings: settings)
      ..available = true;

void main() {
  final cats = [cat('docs'), cat('cfg', settings: true)];
  final leaves = [
    Leaf('Documents/a.txt', 100, 'file', 'docs'),
    Leaf('Documents/sub/b.txt', 200, 'file', 'docs'),
    Leaf('Documents/sub/c.txt', 300, 'file', 'docs'),
    Leaf('.config/app.ini', 50, 'file', 'cfg'),
  ];

  test('folder tri-state reflects child selection', () {
    final m = SelectionModel(cats, leaves);
    m.selectAll(false);
    expect(m.anySelected, isFalse);

    // Tick one file deep in Documents/sub -> ancestors go partial.
    final sub = m.visible().isEmpty ? null : null; // placeholder
    // Build a lookup by walking.
    TreeNode? find(String rel) {
      TreeNode? hit;
      void walk(TreeNode n) {
        if (n.rel == rel && !n.isDir) hit = n;
        for (final c in n.children) walk(c);
      }

      for (final r in m.roots) walk(r);
      return hit;
    }

    m.toggle(find('Documents/sub/b.txt')!);
    expect(m.selectedFiles, 1);
    expect(m.selectedBytes, 200);

    // The docs root should now be partial (1 of 3 leaves).
    final docsRoot = m.roots.firstWhere((r) => r.categoryId == 'docs');
    expect(docsRoot.checkState, 2);

    // Tick the remaining two -> docs root becomes fully selected.
    m.toggle(find('Documents/a.txt')!);
    m.toggle(find('Documents/sub/c.txt')!);
    expect(docsRoot.checkState, 1);
    expect(m.selectedBytes, 600);
    expect(sub, isNull);
  });

  test('toggling a folder selects its whole subtree', () {
    final m = SelectionModel(cats, leaves);
    m.selectAll(false);
    final subDir = _findDirNamed(m, 'sub'); // the sub folder under Documents
    m.toggle(subDir);
    expect(m.selectedFiles, 2); // b.txt + c.txt
    expect(m.selectedBytes, 500);
    expect(subDir.checkState, 1);
  });

  test('Safe mode excludes settings categories; Recommended includes them', () {
    final m = SelectionModel(cats, leaves);
    m.applyMode((c) => !c.settings); // Safe
    expect(m.includedRels().contains('.config/app.ini'), isFalse);
    expect(m.includedRels().contains('Documents/a.txt'), isTrue);

    m.applyMode((_) => true); // Recommended
    expect(m.includedRels().contains('.config/app.ini'), isTrue);
    expect(m.selectedFiles, 4);
    expect(m.selectedBytes, 650);
  });
}

TreeNode _findDirNamed(SelectionModel m, String name) {
  TreeNode? hit;
  void walk(TreeNode n) {
    if (n.name == name && n.isDir && n.depth > 0) hit = n;
    for (final c in n.children) walk(c);
  }

  for (final r in m.roots) walk(r);
  return hit!;
}
