// Native window decorations surround compact, keyboard-accessible app content.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/strings.dart';
import '../platform/desktop_window.dart';
import '../state/transfer_activity.dart';

class DesktopWindowFrame extends ConsumerWidget {
  const DesktopWindowFrame({
    super.key,
    required this.strings,
    required this.status,
    required this.child,
  });
  final S strings;
  final Widget status;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final activity = ref.watch(transferActivityProvider);
    final total = activity.sending + activity.receiving;
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(child: child),
            DecoratedBox(
              decoration: BoxDecoration(
                color: theme.platform == TargetPlatform.macOS
                    ? colors.surfaceContainerLow
                    : colors.surface,
                border: Border(
                  top: BorderSide(color: colors.outlineVariant, width: 0.5),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 6, 2),
                child: Row(
                  children: [
                    Expanded(child: status),
                    if (total > 0) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Tooltip(
                          message: strings('activity.running')
                              .replaceFirst('{n}', '$total'),
                          child: Text(
                            strings('activity.running')
                                .replaceFirst('{n}', '$total'),
                            key: const Key('desktop-activity'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.primary,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    ListenableBuilder(
                      listenable: DesktopWindow.instance,
                      builder: (context, _) {
                        final pinned = DesktopWindow.instance.pinned;
                        return IconButton(
                          key: const Key('window-pin-toggle'),
                          tooltip: strings(
                            pinned ? 'window.unpin' : 'window.pin',
                          ),
                          isSelected: pinned,
                          selectedIcon: const Icon(Icons.push_pin, size: 14),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(26, 24),
                            padding: const EdgeInsets.all(4),
                            foregroundColor: pinned
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                          onPressed: DesktopWindow.instance.togglePinned,
                          icon: const Icon(Icons.push_pin_outlined, size: 14),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DesktopLayout extends ConsumerWidget {
  const DesktopLayout({
    super.key,
    required this.strings,
    required this.selectedIndex,
    required this.onSelected,
    required this.child,
  });
  final S strings;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final mac = theme.platform == TargetPlatform.macOS;
    final activity = ref.watch(transferActivityProvider);
    return CallbackShortcuts(
      bindings: {
        for (final (index, key) in [
          (0, LogicalKeyboardKey.digit1),
          (1, LogicalKeyboardKey.digit2),
          (2, LogicalKeyboardKey.digit3),
          (2, LogicalKeyboardKey.comma),
        ])
          SingleActivator(key, meta: mac, control: !mac): () =>
              onSelected(index),
      },
      child: Focus(
        autofocus: true,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: mac ? colors.surfaceContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Padding(
                  padding: EdgeInsets.all(mac ? 2 : 0),
                  child: Row(
                    children: [
                      _tab(context, 0, 'nav.send', mac, activity.sending),
                      _tab(context, 1, 'nav.receive', mac, activity.receiving),
                      _tab(context, 2, 'nav.settings', mac, 0),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }

  Widget _tab(
    BuildContext context,
    int index,
    String label,
    bool mac,
    int count,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selected = selectedIndex == index;
    return Expanded(
      child: Semantics(
        selected: selected,
        label: count > 0
            ? '${strings(label)}, ${strings('activity.running').replaceFirst('{n}', '$count')}'
            : null,
        child: Container(
          decoration: BoxDecoration(
            color: mac && selected ? colors.surfaceContainerLow : null,
            borderRadius: BorderRadius.circular(5),
            boxShadow: mac && selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: TextButton(
            key: ValueKey('desktop-tab-$index'),
            onPressed: () => onSelected(index),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 26),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              foregroundColor: selected
                  ? colors.onSurface
                  : colors.onSurfaceVariant,
              textStyle: theme.textTheme.labelLarge?.copyWith(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        strings(label),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (count > 0) ...[
                      const SizedBox(width: 4),
                      Container(
                        key: ValueKey('desktop-count-$index'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          count > 99 ? '99+' : '$count',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10,
                            color: colors.primary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (!mac) ...[
                  const SizedBox(height: 5),
                  Container(
                    height: 2,
                    width: 18,
                    decoration: BoxDecoration(
                      color: selected ? colors.primary : Colors.transparent,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
