import 'package:flutter/material.dart';

import '../core/transfer.dart';
import '../models/wizard_state.dart';
import '../widgets/common.dart';
import '../widgets/progress_view.dart';
import 'done_screen.dart';

/// OLD computer after pairing: serves the new computer's requests and shows
/// what's happening — waiting, scanning, sending, sent.
class ConnectedScreen extends StatefulWidget {
  const ConnectedScreen(
      {super.key, required this.state, required this.peerName});
  final WizardState state;
  final String peerName;

  @override
  State<ConnectedScreen> createState() => _ConnectedScreenState();
}

class _ConnectedScreenState extends State<ConnectedScreen> {
  late final SenderController sender;

  @override
  void initState() {
    super.initState();
    final session = widget.state.session!;
    sender = SenderController(session, session);
    widget.state.sender = sender;
    sender.addListener(_onChange);
    // After the first frame: serve() notifies listeners synchronously, which
    // must not trigger setState while this widget is still mounting.
    WidgetsBinding.instance.addPostFrameCallback((_) => sender.serve());
  }

  @override
  void dispose() {
    sender.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    if (sender.state == TransferState.done) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) =>
              DoneScreen(state: widget.state, source: sender, sending: true)));
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (sender.state) {
      case TransferState.transferring:
        return WizardScaffold(
          title: 'Sending to ${widget.peerName}…',
          subtitle: 'Keep both computers on until this finishes.',
          showBack: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ProgressView(source: sender),
              const SizedBox(height: 24),
              Text(
                '🔒 If anything interrupts this, Clone Studio continues from '
                'exactly where it left off.',
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
      case TransferState.error:
        return WizardScaffold(
          title: 'Paused — nothing was lost',
          subtitle: sender.errorMessage ?? '',
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
      default:
        final scanning = sender.state == TransferState.scanning;
        return WizardScaffold(
          title: 'Connected! ✅',
          subtitle: 'The two computers are now securely linked.',
          showBack: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('💻', style: TextStyle(fontSize: 34)),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            child: Icon(Icons.sync_alt_rounded,
                                size: 30,
                                color:
                                    Theme.of(context).colorScheme.primary),
                          ),
                          const Text('✨', style: TextStyle(fontSize: 34)),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Text(widget.peerName,
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(
                        scanning
                            ? 'Sizing up what can move over…'
                            : 'Now choose what moves over — on the NEW computer.',
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(
                                color: Theme.of(context)
                                    .textTheme
                                    .bodyLarge
                                    ?.color
                                    ?.withValues(alpha: 0.6)),
                      ),
                      if (scanning) ...[
                        const SizedBox(height: 16),
                        const LinearProgressIndicator(),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
    }
  }
}
