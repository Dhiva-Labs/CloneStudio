import 'package:flutter/material.dart';

import '../core/transfer.dart';
import '../models/wizard_state.dart';
import '../widgets/common.dart';
import '../widgets/progress_view.dart';
import 'done_screen.dart';

/// Live transfer screen driven by the real engine. Used for receiving over
/// the network, importing from a drive, and exporting to a drive.
class TransferScreen extends StatefulWidget {
  const TransferScreen({
    super.key,
    required this.state,
    required this.source,
    required this.sending,
    this.starter,
  });

  final WizardState state;
  final ProgressSource source;
  final bool sending;
  final Future<void> Function()? starter;

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  @override
  void initState() {
    super.initState();
    widget.source.addListener(_onChange);
    widget.starter?.call();
  }

  @override
  void dispose() {
    widget.source.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    if (widget.source.state == TransferState.done) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => DoneScreen(
              state: widget.state,
              source: widget.source,
              sending: widget.sending)));
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    if (source.state == TransferState.error) {
      return WizardScaffold(
        title: 'Paused — nothing was lost',
        subtitle: source.errorMessage ?? 'Something interrupted the transfer.',
        showBack: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🔌', style: TextStyle(fontSize: 64)),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.home_rounded),
              label: const Text('Back to the start'),
              onPressed: () {
                widget.state.reset();
                Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          ],
        ),
      );
    }

    return WizardScaffold(
      title: widget.sending
          ? 'Copying your things…'
          : 'Moving your things over…',
      subtitle:
          'You can leave the computer alone now. We’ll show a receipt when '
          'it’s done.',
      showBack: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ProgressView(source: source),
          const SizedBox(height: 24),
          Text(
            '🔒 If anything interrupts this, Clone Studio continues from '
            'exactly where it left off. Nothing is ever lost.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.color
                    ?.withValues(alpha: 0.55)),
          ),
        ],
      ),
    );
  }
}
