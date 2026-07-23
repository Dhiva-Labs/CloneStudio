import 'dart:async';

import 'package:flutter/material.dart';

import '../core/bundle.dart';
import '../core/scanner.dart';
import '../core/transfer.dart';
import '../models/selection.dart';
import '../models/wizard_state.dart';
import '../widgets/common.dart';
import 'file_tree_screen.dart';
import 'preflight_screen.dart';
import 'transfer_screen.dart';

/// USB-drive transport, wired to real mounts. The list refreshes every two
/// seconds so plugging a drive in while on this screen just works.
class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key, required this.state});
  final WizardState state;

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  List<DriveLocation> drives = [];
  Timer? _timer;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final found = await listDrives();
    if (mounted) {
      setState(() {
        drives = found;
        _loaded = true;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _pickForExport(DriveLocation d) {
    // Selection was already made before transport; go straight to the
    // pre-flight checks, which run the export.
    widget.state.drivePath = d.path;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PreflightScreen(state: widget.state)));
  }

  void _pickForImport(DriveLocation d) {
    final st = widget.state;
    st.drivePath = d.path;
    final manifest = BundleReader.readManifest(d.path);
    final peer = (manifest?['name'] as String?) ?? '';
    final cats = _catsFromManifest(manifest);
    final leaves = _leavesFromManifest(manifest);
    st.buildSelectionFromOffer(cats, leaves);

    final receiver = ReceiverController(BundleReader(d.path));
    receiver.peerName = peer;
    st.receiver = receiver;

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FileTreeScreen(
        state: st,
        title: 'Review what’s on the drive',
        subtitle:
            'From ${peer.isEmpty ? 'the old computer' : peer}. Untick anything '
            'you don’t want to restore here.',
        continueLabel: 'Restore it',
        onContinue: (ctx, s) {
          Navigator.of(ctx).pushReplacement(MaterialPageRoute(
            builder: (_) => TransferScreen(
              state: s,
              source: receiver,
              sending: false,
              starter: () =>
                  receiver.importBundle(s.includedRels(), leaves, peer: peer),
            ),
          ));
        },
      ),
    ));
  }

  List<ScanCategory> _catsFromManifest(Map<String, dynamic>? m) {
    final raw = (m?['cats'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return [
      for (final c in raw)
        ScanCategory(
          id: c['id'] as String,
          name: c['name'] as String,
          icon: c['icon'] as String,
          settings: c['settings'] as bool? ?? false,
        )..available = true,
    ];
  }

  List<Leaf> _leavesFromManifest(Map<String, dynamic>? m) {
    final raw = (m?['leaves'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return [for (final l in raw) Leaf.fromWire(l)];
  }

  @override
  Widget build(BuildContext context) {
    final isOld = widget.state.role == DeviceRole.oldDevice;
    final visible = isOld ? drives : drives.where((d) => d.hasBundle).toList();

    return WizardScaffold(
      title: isOld ? 'Pick a drive to copy onto' : 'Plug in your drive',
      subtitle: isOld
          ? 'Plug in a USB drive or external disk. It appears here automatically.'
          : 'The drive you filled on the old computer.',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_loaded)
            const Padding(
              padding: EdgeInsets.all(48),
              child: CircularProgressIndicator(),
            )
          else if (visible.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(36),
                child: Column(
                  children: [
                    const Text('💾', style: TextStyle(fontSize: 56)),
                    const SizedBox(height: 16),
                    Text(
                      isOld
                          ? 'No drive found yet. Plug one in — it shows up '
                            'here by itself.'
                          : 'No Clone Studio transfer found yet. Plug in the '
                            'drive from your old computer.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
            )
          else
            for (final d in visible) ...[
              BigChoiceCard(
                emoji: d.hasBundle && !isOld ? '🎁' : '💾',
                title: isOld
                    ? d.label
                    : 'Transfer from '
                        '${BundleReader.readManifest(d.path)?['name'] ?? d.label}',
                description: isOld
                    ? '${prettyBytes(d.freeBytes)} free'
                    : '${prettyBytes((BundleReader.readManifest(d.path)?['bytes'] as int?) ?? 0)}'
                        ' · tap to restore it here',
                highlighted: !isOld,
                onTap: () =>
                    isOld ? _pickForExport(d) : _pickForImport(d),
              ),
              const SizedBox(height: 14),
            ],
        ],
      ),
    );
  }
}
