import 'dart:io';

import 'package:flutter/material.dart';

import '../core/bundle.dart';
import '../core/scanner.dart';
import '../core/transfer.dart';
import '../models/selection.dart';
import '../models/wizard_state.dart';
import '../widgets/common.dart';
import 'transfer_screen.dart';

enum _CheckResult { pending, ok, warn, blocked }

class _Check {
  _Check(this.label);
  String label;
  _CheckResult result = _CheckResult.pending;
}

/// Pre-flight checks for a USB-drive export. (Network transfers no longer
/// pass through here — the source simply serves its selection once the new
/// computer connects, and the new computer checks its own free space.)
class PreflightScreen extends StatefulWidget {
  const PreflightScreen({super.key, required this.state});
  final WizardState state;

  @override
  State<PreflightScreen> createState() => _PreflightScreenState();
}

class _PreflightScreenState extends State<PreflightScreen> {
  late final List<_Check> checks;
  bool finished = false;

  @override
  void initState() {
    super.initState();
    checks = [
      _Check('Enough free space on the drive'),
      _Check('Plugged into power'),
      _Check('Drive is ready'),
    ];
    _run();
  }

  Future<void> _run() async {
    final st = widget.state;
    final needed = st.selectedBytes;

    final free = await freeBytes(st.drivePath!);
    if (free > needed * 1.05) {
      checks[0].result = _CheckResult.ok;
      checks[0].label += ' (${prettyBytes(free)} free)';
    } else {
      checks[0].result = _CheckResult.blocked;
      checks[0].label = 'Not enough space: ${prettyBytes(needed)} needed, only '
          '${prettyBytes(free)} free. Go back and pick less.';
    }
    if (mounted) setState(() {});

    checks[1].result =
        await _onBattery() ? _CheckResult.warn : _CheckResult.ok;
    if (checks[1].result == _CheckResult.warn) {
      checks[1].label = 'Running on battery — plug in if you can';
    }
    if (mounted) setState(() {});

    checks[2].result = Directory(st.drivePath!).existsSync()
        ? _CheckResult.ok
        : _CheckResult.blocked;
    if (mounted) setState(() => finished = true);
  }

  Future<bool> _onBattery() async {
    try {
      final supplies = Directory('/sys/class/power_supply');
      if (!supplies.existsSync()) return false;
      var hasBattery = false;
      var acOnline = false;
      for (final d in supplies.listSync()) {
        final name = d.path.split('/').last;
        if (name.startsWith('BAT')) hasBattery = true;
        final online = File('${d.path}/online');
        if (online.existsSync() && online.readAsStringSync().trim() == '1') {
          acOnline = true;
        }
      }
      return hasBattery && !acOnline;
    } catch (_) {
      return false;
    }
  }

  bool get _canStart =>
      finished && !checks.any((c) => c.result == _CheckResult.blocked);

  /// Cats + selected leaves, so the new computer can build its review tree.
  Map<String, dynamic> _manifest(SenderController exporter) {
    final st = widget.state;
    final included = st.includedRels();
    final cats = [
      for (final c in st.scan!.categories)
        if (c.available)
          {'id': c.id, 'name': c.name, 'icon': c.icon, 'settings': c.settings},
    ];
    final leaves = [
      for (final e in st.scan!.leaves)
        if (included.contains(e.relative))
          Leaf(e.relative, e.size, e.kind, e.categoryId).toWire(),
    ];
    return {
      'name': Platform.localHostname,
      'created': DateTime.now().toIso8601String(),
      'bytes': exporter.totalBytes,
      'files': exporter.totalFiles,
      'cats': cats,
      'leaves': leaves,
    };
  }

  void _start() {
    final st = widget.state;
    final writer = BundleWriter(st.drivePath!);
    final exporter = SenderController(writer)
      ..setPlan(st.scan!, st.includedRels());
    st.exporter = exporter;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => TransferScreen(
        state: st,
        source: exporter,
        sending: true,
        starter: () async {
          await writer.open();
          await exporter.exportBundle();
          if (exporter.state == TransferState.done) {
            await writer.writeManifest(_manifest(exporter));
          }
          await writer.close();
        },
      ),
    ));
  }

  Widget _icon(_CheckResult r, ColorScheme scheme) => switch (r) {
        _CheckResult.pending => SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
                strokeWidth: 3, color: scheme.primary.withValues(alpha: 0.5))),
        _CheckResult.ok => Icon(Icons.check_circle_rounded,
            color: Colors.green.shade600, size: 28),
        _CheckResult.warn => Icon(Icons.warning_amber_rounded,
            color: Colors.orange.shade700, size: 28),
        _CheckResult.blocked =>
          Icon(Icons.cancel_rounded, color: scheme.error, size: 28),
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return WizardScaffold(
      title: 'Quick check before we start',
      subtitle: 'Copying ${prettyBytes(widget.state.selectedBytes)} to the drive.',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                children: [
                  for (final c in checks)
                    ListTile(
                      leading: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: KeyedSubtree(
                            key: ValueKey(c.result),
                            child: _icon(c.result, scheme)),
                      ),
                      title: Text(c.label),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),
          AnimatedOpacity(
            opacity: _canStart ? 1 : 0.35,
            duration: const Duration(milliseconds: 300),
            child: FilledButton.icon(
              icon: const Icon(Icons.rocket_launch_rounded),
              label: const Text('Start copying'),
              onPressed: _canStart ? _start : null,
            ),
          ),
        ],
      ),
    );
  }
}
