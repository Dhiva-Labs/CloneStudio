import 'package:flutter/material.dart';

import '../models/selection.dart';
import '../models/wizard_state.dart';

/// Full file-by-file selection tree with tri-state folders. Used both on the
/// OLD computer ("choose what to send") and the NEW computer ("review what's
/// coming, untick anything you don't want").
class FileTreeScreen extends StatefulWidget {
  const FileTreeScreen({
    super.key,
    required this.state,
    required this.title,
    required this.subtitle,
    required this.continueLabel,
    required this.onContinue,
  });

  final WizardState state;
  final String title;
  final String subtitle;
  final String continueLabel;
  final void Function(BuildContext, WizardState) onContinue;

  @override
  State<FileTreeScreen> createState() => _FileTreeScreenState();
}

class _FileTreeScreenState extends State<FileTreeScreen> {
  SelectionModel get model => widget.state.selection!;

  String _fileEmoji(TreeNode n) {
    if (n.kind == 'app') return '📦';
    if (n.kind == 'symlink') return '🔗';
    if (n.kind == 'virtual') return '🧩';
    final name = n.name.toLowerCase();
    final dot = name.lastIndexOf('.');
    final ext = dot >= 0 ? name.substring(dot + 1) : '';
    return switch (ext) {
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'heic' || 'bmp' => '🖼️',
      'mp4' || 'mkv' || 'mov' || 'avi' || 'webm' => '🎬',
      'mp3' || 'flac' || 'wav' || 'ogg' || 'm4a' => '🎵',
      'pdf' => '📕',
      'doc' || 'docx' || 'odt' || 'txt' || 'md' || 'rtf' => '📄',
      'zip' || 'tar' || 'gz' || 'xz' || '7z' || 'iso' => '🗜️',
      'sh' || 'py' || 'dart' || 'js' || 'ts' || 'c' || 'cpp' || 'rs' => '📜',
      _ => '📄',
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = model.visible();

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (Navigator.of(context).canPop())
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: IconButton.filledTonal(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.arrow_back),
                          ),
                        ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.title,
                                style:
                                    Theme.of(context).textTheme.headlineSmall),
                            const SizedBox(height: 2),
                            Text(
                              widget.subtitle,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.color
                                          ?.withValues(alpha: 0.6)),
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            setState(() => model.selectAll(true)),
                        icon: const Icon(Icons.done_all, size: 18),
                        label: const Text('All'),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            setState(() => model.selectAll(false)),
                        icon: const Icon(Icons.remove_done, size: 18),
                        label: const Text('None'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: Card(
                      clipBehavior: Clip.antiAlias,
                      child: Scrollbar(
                        child: ListView.builder(
                          primary: true,
                          itemCount: visible.length,
                          itemExtent: 46,
                          itemBuilder: (context, i) =>
                              _row(context, visible[i], scheme),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${model.selectedFiles} items · '
                          '${prettyBytes(model.selectedBytes)} selected',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      FilledButton.icon(
                        icon: const Icon(Icons.arrow_forward),
                        label: Text(widget.continueLabel),
                        onPressed: model.anySelected
                            ? () => widget.onContinue(context, widget.state)
                            : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, TreeNode n, ColorScheme scheme) {
    final indent = 8.0 + n.depth * 20.0;
    final tri = n.checkState;
    return InkWell(
      onTap: n.isDir
          ? () => setState(() => n.expanded = !n.expanded)
          : () => setState(() => model.toggle(n)),
      child: Padding(
        padding: EdgeInsets.only(left: indent, right: 12),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: n.isDir
                  ? Icon(
                      n.expanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 22,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    )
                  : const SizedBox.shrink(),
            ),
            SizedBox(
              width: 34,
              child: Checkbox(
                tristate: true,
                value: tri == 1
                    ? true
                    : tri == 0
                        ? false
                        : null,
                onChanged: (_) => setState(() => model.toggle(n)),
              ),
            ),
            Text(n.isDir ? (n.depth == 0 ? n.icon : '📁') : _fileEmoji(n),
                style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                n.isDir && n.depth == 0 ? n.name : n.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: n.depth == 0 ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              n.categoryId == 'apps'
                  ? (n.isDir ? '${n.count} apps' : '')
                  : prettyBytes(n.size),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.color
                      ?.withValues(alpha: 0.5)),
            ),
          ],
        ),
      ),
    );
  }
}
