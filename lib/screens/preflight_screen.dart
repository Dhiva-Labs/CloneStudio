import 'dart:io';

import 'package:flutter/material.dart';

import '../core/bundle.dart';
import '../core/scanner.dart';
import '../core/transfer.dart';
import '../models/wizard_state.dart';
import '../widgets/common.dart';
import 'transfer_screen.dart';

enum _CheckResult { pending, ok, warn, blocked }

class _Check {
  _Check(this.label);
  String label;
  _CheckResult result = _CheckResult.pending;
}

/// Real pre-flight checks. Red blocks the start button, amber only warns.
class PreflightScreen extends StatefulWidget {
  const PreflightScreen({super.key, required this.state});
  final WizardState state;

  @override
  State<PreflightScreen> createState() => _PreflightScreenState();
}

class _PreflightScreenState extends State<PreflightScreen> {
  late final List<_Check> checks;
  bool finished = false;

  bool get _isExport =>
      widget.state.role == DeviceRole.oldDevice &&
      widget.state.transport == Transport.usbDrive;

  @override
  void initState() {
    super.initState();
    checks = [
      _Check(_isExport
          ? 'Enough free space on the drive'
          : 'Enough free space on this computer'),
      _Check('Plugged into power'),
      _Check(_isExport ? 'Drive is ready' : 'Connection is healthy'),
    ];
    _run();
  }

  Future<void> _run() async {
    final st = widget.state;
    final needed = st.selectedBytes;

    // 1. Free space where the data will land.
    final destPath = _isExport ? st.drivePath! : targetRoot();
    final free = await freeBytes(destPath);
    if (free > needed * 1.05) {
      checks[0].result = _CheckResult.ok;
      checks[0].label += ' (${prettyBytes(free)} free)';
    } else {
      checks[0].result = _CheckResult.blocked;
      checks[0].label =
          'Not enough space: ${prettyBytes(needed)} needed, only '
          '${prettyBytes(free)} free. Go back and pick less.';
    }
    if (mounted) setState(() {});

    // 2. Power: warn when running on battery.
    checks[1].result = await _onBattery()
        ? _CheckResult.warn
        : _CheckResult.ok;
    if (checks[1].result == _CheckResult.warn) {
      checks[1].label = 'Running on battery — plug in if you can';
    }
    if (mounted) setState(() {});

    // 3. The pipe we're about to use.
    if (_isExport) {
      checks[2].result = Directory(st.drivePath!).existsSync()
          ? _CheckResult.ok
          : _CheckResult.blocked;
    } else {
      checks[2].result = (st.session != null && !st.session!.closed)
          ? _CheckResult.ok
          : _CheckResult.blocked;
      if (checks[2].result == _CheckResult.blocked) {
        checks[2].label =
            'The connection was lost. Go back and connect again.';
      }
    }
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

  void _start() {
    final st = widget.state;
    if (_isExport) {
      final writer = BundleWriter(st.drivePath!);
      final exporter = SenderController(writer);
      st.exporter = exporter;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => TransferScreen(
                state: st,
                source: exporter,
                sending: true,
                starter: () async {
                  await writer.open();
                  await exporter.send(st.selected.toList(), []);
                  if (exporter.state == TransferState.done) {
                    await writer.writeManifest({
                      'name': Platform.localHostname,
                      'created': DateTime.now().toIso8601String(),
                      'bytes': exporter.totalBytes,
                      'files': exporter.totalFiles,
                    });
                  }
                  await writer.close();
                },
              )));
    } else {
      final receiver = st.receiver!;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => TransferScreen(
                state: st,
                source: receiver,
                sending: false,
                starter: () => receiver.start(st.selected.toList()),
              )));
    }
  }

  Widget _icon(_CheckResult r, ColorScheme scheme) => switch (r) {
        _CheckResult.pending => SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
                strokeWidth: 3,
                color: scheme.primary.withValues(alpha: 0.5))),
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
      subtitle:
          '${_isExport ? 'Copying' : 'Moving'} ${prettyBytes(widget.state.selectedBytes)} '
          'in ${widget.state.mode?.title ?? ''} mode.',
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
                            key: ValueKey(c.result), child: _icon(c.result, scheme)),
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
              label: Text(_isExport ? 'Start copying' : 'Start the transfer'),
              onPressed: _canStart ? _start : null,
            ),
          ),
        ],
      ),
    );
  }
}
