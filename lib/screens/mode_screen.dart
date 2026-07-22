import 'package:flutter/material.dart';

import '../models/wizard_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'preflight_screen.dart';
import 'selection_screen.dart';

class ModeScreen extends StatelessWidget {
  const ModeScreen({super.key, required this.state});
  final WizardState state;

  void _pick(BuildContext context, TransferMode m) {
    if (m == TransferMode.wholeDisk) {
      _confirmWholeDisk(context);
      return;
    }
    state.applyMode(m);
    final next = m == TransferMode.custom
        ? SelectionScreen(state: state)
        : PreflightScreen(state: state);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => next));
  }

  void _confirmWholeDisk(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('This erases the new computer'),
        content: const Text(
            'Whole Disk Clone replaces EVERYTHING on the new computer — its '
            'operating system and any files on it — with an exact copy of the '
            'old one.\n\nIt also needs a USB stick to start the new computer '
            'from. Clone Studio will guide you through creating it.\n\n'
            '(Available in a later build — this is a preview.)'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Go back')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final safeBytes = state.bytesForMode(TransferMode.safe);
    final recBytes = state.bytesForMode(TransferMode.recommended);
    return WizardScaffold(
      title: 'What should move over?',
      subtitle: 'Not sure? The highlighted choice is right for most people.',
      maxWidth: 760,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BigChoiceCard(
              emoji: '🛡️',
              title: TransferMode.safe.title,
              description:
                  '${TransferMode.safe.blurb} (${prettyBytes(safeBytes)})',
              badge: const RiskBadge(label: 'SAFEST', color: Colors.green),
              onTap: () => _pick(context, TransferMode.safe),
            ),
            const SizedBox(height: 14),
            BigChoiceCard(
              emoji: '⭐',
              title: TransferMode.recommended.title,
              description:
                  '${TransferMode.recommended.blurb} (${prettyBytes(recBytes)})',
              badge: const RiskBadge(label: 'RECOMMENDED', color: Colors.blue),
              highlighted: true,
              onTap: () => _pick(context, TransferMode.recommended),
            ),
            const SizedBox(height: 14),
            BigChoiceCard(
              emoji: '🗄️',
              title: TransferMode.wholeDisk.title,
              description: TransferMode.wholeDisk.blurb,
              badge:
                  const RiskBadge(label: 'ERASES TARGET', color: Colors.orange),
              onTap: () => _pick(context, TransferMode.wholeDisk),
            ),
            const SizedBox(height: 14),
            BigChoiceCard(
              emoji: '🎛️',
              title: TransferMode.custom.title,
              description: TransferMode.custom.blurb,
              badge: const RiskBadge(label: 'ADVANCED', color: Colors.purple),
              onTap: () => _pick(context, TransferMode.custom),
            ),
          ],
        ),
      ),
    );
  }
}
