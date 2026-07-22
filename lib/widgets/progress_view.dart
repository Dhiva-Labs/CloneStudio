import 'package:flutter/material.dart';

import '../core/transfer.dart';
import '../models/wizard_state.dart';

/// The live progress card every transfer screen shows, fed by a
/// [ProgressSource] — receiving, sending or exporting all look the same.
class ProgressView extends StatelessWidget {
  const ProgressView({super.key, required this.source});
  final ProgressSource source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final speed = source.speed;
    final speedText = speed <= 0
        ? ''
        : '${prettyBytes(speed.round())}/s';
    String eta = '';
    if (speed > 1024 && source.totalBytes > source.doneBytes) {
      final secs = (source.totalBytes - source.doneBytes) / speed;
      eta = secs > 90
          ? ' · about ${(secs / 60).ceil()} min left'
          : ' · under a minute left';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('${(source.progress * 100).round()}%',
                    style: Theme.of(context)
                        .textTheme
                        .headlineLarge
                        ?.copyWith(color: scheme.primary)),
                const Spacer(),
                Text('$speedText$eta',
                    style: Theme.of(context).textTheme.bodyLarge),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                  value: source.totalBytes == 0 ? null : source.progress,
                  minHeight: 14),
            ),
            const SizedBox(height: 16),
            Text(
              '${prettyBytes(source.doneBytes)} of ${prettyBytes(source.totalBytes)}'
              '${source.currentItem.isEmpty ? '' : '   ·   ${source.currentItem}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.color
                      ?.withValues(alpha: 0.6)),
            ),
          ],
        ),
      ),
    );
  }
}
