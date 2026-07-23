import 'package:flutter/material.dart';

import '../core/scanner.dart';
import '../models/wizard_state.dart';
import '../widgets/common.dart';
import 'mode_screen.dart';

/// OLD computer: "Sizing up your stuff…" — scans the local home, builds the
/// selection tree, then moves on to choosing what to take. Happens before any
/// connection, so you decide what leaves this computer first.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.state});
  final WizardState state;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  String? error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final result = await scanEverything();
      widget.state.buildSelectionFromScan(result);
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Something went wrong while looking through your files. Please '
            'go back and try again.');
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ModeScreen(state: widget.state)));
  }

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      title: error == null ? 'Sizing up your stuff…' : 'Hmm, that didn’t work',
      subtitle: error ??
          'Looking through your files and adding up sizes. Big folders take '
              'a moment.',
      child: error == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(48),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: CircularProgressIndicator(strokeWidth: 5),
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
