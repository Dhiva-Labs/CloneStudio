import 'dart:io';

import 'package:flutter/material.dart';

import '../core/scanner.dart';
import '../core/transfer.dart';
import '../models/wizard_state.dart';
import '../widgets/common.dart';

/// The receipt, with real numbers from the engine.
class DoneScreen extends StatelessWidget {
  const DoneScreen(
      {super.key,
      required this.state,
      required this.source,
      required this.sending});

  final WizardState state;
  final ProgressSource source;
  final bool sending;

  bool get _isExport =>
      state.role == DeviceRole.oldDevice &&
      state.transport == Transport.usbDrive;

  @override
  Widget build(BuildContext context) {
    final mins = source.startedAt == null
        ? 0
        : DateTime.now().difference(source.startedAt!).inMinutes;
    final tookText = mins < 1 ? 'under a minute' : '$mins min';
    final hasApps = state.selected.contains('apps');
    final failed =
        source is ReceiverController ? (source as ReceiverController).failedFiles : 0;

    final title = _isExport
        ? 'Safe to unplug! 🎉'
        : sending
            ? 'All sent! 🎉'
            : 'Welcome to your new computer! 🎉';
    final subtitle = _isExport
        ? 'Now plug the drive into your NEW computer and open Clone Studio there.'
        : 'Everything arrived safely. Here’s your receipt.';

    return WizardScaffold(
      title: title,
      subtitle: subtitle,
      showBack: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  children: [
                    _row(context, '📁',
                        '${source.doneFiles} files ${_isExport ? 'copied' : 'moved'}',
                        prettyBytes(source.doneBytes)),
                    if (source.skippedFiles > 0) ...[
                      const Divider(height: 28),
                      _row(context, '⏭️', 'Already there from last time',
                          '${source.skippedFiles}'),
                    ],
                    const Divider(height: 28),
                    _row(context, '⏱️', 'Time taken', tookText),
                    const Divider(height: 28),
                    failed == 0
                        ? _row(context, '✅', 'Everything double-checked',
                            'Verified')
                        : _row(context, '⚠️',
                            'Files that need another pass', '$failed'),
                  ],
                ),
              ),
            ),
            if (hasApps && !sending && !_isExport) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Text('📦 Your apps came over as a list',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(
                        'To install them on this computer, open a terminal and run:\n'
                        'bash ~/CloneStudio-Restore/packages/install_apps.sh',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('Install my apps now'),
                        onPressed: () => _installApps(context),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 28),
            FilledButton.icon(
              icon: const Icon(Icons.home_rounded),
              label: const Text('Finish'),
              onPressed: () {
                state.reset();
                Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _installApps(BuildContext context) async {
    final script =
        '${targetRoot()}/CloneStudio-Restore/packages/install_apps.sh';
    final messenger = ScaffoldMessenger.of(context);
    try {
      // pkexec asks for the password with the system dialog.
      await Process.start('pkexec', ['bash', script],
          mode: ProcessStartMode.detached);
      messenger.showSnackBar(const SnackBar(
          content: Text(
              'Installing in the background — enter your password when asked.')));
    } catch (_) {
      messenger.showSnackBar(SnackBar(
          content: Text('Could not start the installer. Run manually: '
              'bash $script')));
    }
  }

  Widget _row(BuildContext context, String emoji, String label, String value) {
    return Row(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 26)),
        const SizedBox(width: 16),
        Expanded(
            child:
                Text(label, style: Theme.of(context).textTheme.titleMedium)),
        Text(value,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      ],
    );
  }
}
