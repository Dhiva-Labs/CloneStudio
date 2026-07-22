import 'package:flutter/material.dart';

import '../core/scanner.dart';
import '../core/transfer.dart';
import '../models/wizard_state.dart';
import '../widgets/common.dart';
import 'mode_screen.dart';

/// "Sizing up your stuff…" — fills state.cats with real numbers, either by
/// asking the old computer (network) or scanning locally (USB export).
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.state, required this.local});
  final WizardState state;
  final bool local;

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
    final st = widget.state;
    if (widget.local) {
      st.cats = await scanAll();
    } else {
      final receiver = ReceiverController(st.session!, st.session!);
      st.receiver = receiver;
      final ok = await receiver.requestScan();
      if (!ok) {
        if (mounted) {
          setState(() => error = receiver.errorMessage ??
              'Something went wrong. Please go back and try again.');
        }
        return;
      }
      st.cats = receiver.categories;
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ModeScreen(state: st)));
  }

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      title: error == null ? 'Sizing up your stuff…' : 'Hmm, that didn’t work',
      subtitle: error ??
          'Counting files and adding up sizes. Big folders take a moment.',
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
