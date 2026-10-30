import 'package:flutter/material.dart';

import '../models/wizard_state.dart';
import '../widgets/common.dart';
import 'scan_screen.dart';
import 'transport_screen.dart';

const appVersion = '1.1.1';

class RoleScreen extends StatelessWidget {
  const RoleScreen({super.key, required this.state});
  final WizardState state;

  void _pick(BuildContext context, DeviceRole role) {
    state.reset(); // a fresh journey; closes any leftover connection
    state.setRole(role);
    // The OLD computer chooses what to move *before* connecting; the NEW
    // computer just needs to know how to connect and then reviews the offer.
    final next = role == DeviceRole.oldDevice
        ? ScanScreen(state: state)
        : TransportScreen(state: state);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => next));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Brand mark
                  Center(
                      child: Container(
                    width: 84,
                    height: 84,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          scheme.primary,
                          scheme.primary.withValues(alpha: 0.65),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(26),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.35),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Icon(Icons.swap_horiz_rounded,
                        size: 48, color: Colors.white),
                  )),
                  const SizedBox(height: 24),
                  Text('Clone Studio',
                      textAlign: TextAlign.center, style: t.headlineMedium),
                  const SizedBox(height: 10),
                  Text(
                    'Move everything to your new computer — safely, step by step.',
                    textAlign: TextAlign.center,
                    style: t.bodyLarge?.copyWith(
                        color: t.bodyLarge?.color?.withValues(alpha: 0.65)),
                  ),
                  const SizedBox(height: 40),
                  BigChoiceCard(
                    emoji: '💻',
                    title: 'This is my OLD computer',
                    description: 'The computer your files are on right now.',
                    onTap: () => _pick(context, DeviceRole.oldDevice),
                  ),
                  const SizedBox(height: 16),
                  BigChoiceCard(
                    emoji: '✨',
                    title: 'This is my NEW computer',
                    description:
                        'The computer you want to move everything to.',
                    onTap: () => _pick(context, DeviceRole.newDevice),
                  ),
                  const SizedBox(height: 36),
                  Text(
                    'Version $appVersion · Everything stays between your two '
                    'computers — nothing touches the internet.',
                    textAlign: TextAlign.center,
                    style: t.bodySmall?.copyWith(
                        color: t.bodySmall?.color?.withValues(alpha: 0.45)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
