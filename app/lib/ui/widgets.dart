// Small widgets shared by the pages.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/format.dart';
import '../state/models.dart';
import '../state/providers.dart';

class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [colors.primary, colors.tertiary],
          ),
          borderRadius: BorderRadius.circular(size * 0.3),
          boxShadow: [
            BoxShadow(
              color: colors.primary.withValues(alpha: 0.2),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(
          Icons.swap_horiz_rounded,
          size: size * 0.62,
          color: Colors.white,
        ),
      ),
    );
  }
}

class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 16), trailing!],
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 34),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(icon, color: colors.onSurfaceVariant, size: 23),
          ),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

Color stateColor(BuildContext context, String state) {
  final cs = Theme.of(context).colorScheme;
  switch (state) {
    case 'completed':
      return Colors.green.shade600;
    case 'failed':
    case 'cancelled':
      return cs.error;
    case 'transferring':
    case 'verifying':
      return cs.primary;
    case 'interrupted':
    case 'paused':
      return Colors.orange.shade700;
    default:
      return cs.onSurfaceVariant;
  }
}

class StateChip extends ConsumerWidget {
  const StateChip(this.state, {super.key, this.detail});
  final String state;
  final String? detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final color = stateColor(context, state);
    final text = detail == null || detail!.isEmpty
        ? s.state(state)
        : '${s.state(state)} · $detail';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Progress bar plus rate / eta / path / files line for a live transfer.
class TransferProgressView extends ConsumerWidget {
  const TransferProgressView(this.t, {super.key});
  final TransferInfo t;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final theme = Theme.of(context);
    final active = !t.isTerminal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: t.bytesTotal > 0 ? t.fraction : (active ? null : 0),
            minHeight: 8,
            color: stateColor(context, t.state),
          ),
        ),
        const SizedBox(height: 6),
        DefaultTextStyle(
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          child: Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              Text(
                '${formatPercent(t.fraction)}  '
                '${formatBytes(t.bytesDone)} / ${formatBytes(t.bytesTotal)}',
              ),
              Text('${s('recv.files')} ${t.filesDone}/${t.filesTotal}'),
              if (active) Text('${s('recv.rate')} ${formatRate(t.rateBps)}'),
              if (active) Text('${s('recv.eta')} ${formatEta(t.etaSec)}'),
              Text(
                '${s('recv.path')} ${s.path(t.path.isEmpty ? 'unknown' : t.path)}',
              ),
              if (active && t.lossPermille > 0)
                Text(
                  '${s('recv.loss')} ${(t.lossPermille / 10).toStringAsFixed(1)}%',
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

void showSnack(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
}
