import 'package:flutter/material.dart';

/// Standard wizard page: big title, friendly subtitle, centered content,
/// optional back button. Every screen in the app uses this frame.
class WizardScaffold extends StatelessWidget {
  const WizardScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
    this.showBack = true,
    this.maxWidth = 720,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final bool showBack;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            if (showBack && Navigator.of(context).canPop())
              Positioned(
                top: 16,
                left: 16,
                child: IconButton.filledTonal(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(title, textAlign: TextAlign.center, style: t.headlineMedium),
                      if (subtitle != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          subtitle!,
                          textAlign: TextAlign.center,
                          style: t.bodyLarge?.copyWith(
                              color: t.bodyLarge?.color?.withValues(alpha: 0.65)),
                        ),
                      ],
                      const SizedBox(height: 32),
                      Flexible(child: child),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Large tappable card with an emoji icon, title, description and optional
/// trailing badge. The primary building block of every choice screen.
class BigChoiceCard extends StatelessWidget {
  const BigChoiceCard({
    super.key,
    required this.emoji,
    required this.title,
    required this.description,
    required this.onTap,
    this.badge,
    this.highlighted = false,
  });

  final String emoji;
  final String title;
  final String description;
  final VoidCallback onTap;
  final Widget? badge;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: highlighted
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 32)),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(title,
                              style: Theme.of(context).textTheme.titleLarge),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: 10),
                          badge!,
                        ],
                        if (highlighted) ...[
                          const SizedBox(width: 10),
                          Icon(Icons.stars_rounded,
                              size: 20, color: scheme.primary),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.color
                              ?.withValues(alpha: 0.65)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.chevron_right_rounded,
                  color: scheme.onSurface.withValues(alpha: 0.35)),
            ],
          ),
        ),
      ),
    );
  }
}
