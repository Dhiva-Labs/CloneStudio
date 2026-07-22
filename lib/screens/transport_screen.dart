import 'package:flutter/material.dart';

import '../models/wizard_state.dart';
import '../widgets/common.dart';
import 'drive_screens.dart';
import 'pairing_screens.dart';

class TransportScreen extends StatelessWidget {
  const TransportScreen({super.key, required this.state});
  final WizardState state;

  void _pick(BuildContext context, Transport t) {
    state.setTransport(t);
    final Widget next;
    if (t == Transport.usbDrive) {
      next = DriveScreen(state: state);
    } else if (state.role == DeviceRole.oldDevice) {
      next = PinDisplayScreen(state: state);
    } else {
      next = DiscoveryScreen(state: state);
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => next));
  }

  @override
  Widget build(BuildContext context) {
    final isOld = state.role == DeviceRole.oldDevice;
    return WizardScaffold(
      title: 'How should the two computers talk?',
      subtitle: isOld
          ? 'Pick the same option on both computers.'
          : 'Pick the same option you chose on the old computer.',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BigChoiceCard(
            emoji: '📶',
            title: 'Over Wi-Fi / network',
            description:
                'Both computers on, connected to the same Wi-Fi. Found automatically.',
            highlighted: true,
            onTap: () => _pick(context, Transport.network),
          ),
          const SizedBox(height: 16),
          BigChoiceCard(
            emoji: '🔌',
            title: 'Direct cable',
            description:
                'Plug a network cable between the two computers. Fastest way.',
            onTap: () => _pick(context, Transport.cable),
          ),
          const SizedBox(height: 16),
          BigChoiceCard(
            emoji: '💾',
            title: 'USB drive or external disk',
            description:
                'No network needed. Copy to a drive, plug it into the new computer.',
            onTap: () => _pick(context, Transport.usbDrive),
          ),
        ],
      ),
    );
  }
}
