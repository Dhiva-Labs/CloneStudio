import 'package:flutter/material.dart';

import '../models/wizard_state.dart';
import '../widgets/common.dart';
import 'preflight_screen.dart';

/// Custom mode: the real category list with checkboxes and a live total.
class SelectionScreen extends StatelessWidget {
  const SelectionScreen({super.key, required this.state});
  final WizardState state;

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      title: 'Pick what moves over',
      subtitle: 'Tick anything you want on the new computer.',
      maxWidth: 680,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          return Column(
            children: [
              Expanded(
                child: Card(
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: state.cats.length,
                    separatorBuilder: (_, _) => Divider(
                        height: 1,
                        indent: 68,
                        color: Theme.of(context)
                            .colorScheme
                            .outline
                            .withValues(alpha: 0.12)),
                    itemBuilder: (context, i) {
                      final c = state.cats[i];
                      final subtitle = c.available
                          ? (c.note != null
                              ? '${c.note} · ${prettyBytes(c.sizeBytes)}'
                              : prettyBytes(c.sizeBytes))
                          : (c.note ?? 'Not available');
                      return CheckboxListTile(
                        value: c.available && state.selected.contains(c.id),
                        onChanged:
                            c.available ? (_) => state.toggle(c) : null,
                        secondary:
                            Text(c.icon, style: const TextStyle(fontSize: 26)),
                        title: Text(c.name),
                        subtitle: Text(subtitle),
                        controlAffinity: ListTileControlAffinity.trailing,
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Total: ${prettyBytes(state.selectedBytes)}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  FilledButton.icon(
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Continue'),
                    onPressed: state.selected.isEmpty
                        ? null
                        : () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => PreflightScreen(state: state))),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
