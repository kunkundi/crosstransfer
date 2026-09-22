// Shared window controls remain available above every desktop route.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../i18n/strings.dart';
import '../platform/desktop_window.dart';
import 'widgets.dart';

class DesktopWindowFrame extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: colors.surface,
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 42,
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onPanStart: (_) => windowManager.startDragging(),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Row(
                          children: [
                            const AppMark(size: 20),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                strings('app.title'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: status,
                  ),
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
                        selectedIcon: const Icon(Icons.push_pin, size: 17),
                        style: IconButton.styleFrom(
                          backgroundColor: pinned
                              ? colors.primaryContainer
                              : Colors.transparent,
                          foregroundColor: pinned
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                        onPressed: DesktopWindow.instance.togglePinned,
                        icon: const Icon(Icons.push_pin_outlined, size: 17),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: strings('window.close'),
                    // The tray listener hides on close. Without a tray this
                    // actually closes, rather than stranding a hidden process.
                    onPressed: () => windowManager.close(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class DesktopLayout extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Row(
                children: [
                  _tab(context, 0, 'nav.send'),
                  _tab(context, 1, 'nav.receive'),
                  _tab(context, 2, 'nav.settings'),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }

  Widget _tab(BuildContext context, int index, String label) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selected = selectedIndex == index;
    return Expanded(
      child: Semantics(
        selected: selected,
        child: TextButton(
          key: ValueKey('desktop-tab-$index'),
          onPressed: () => onSelected(index),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 28),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 7),
            foregroundColor: selected
                ? colors.primary
                : colors.onSurfaceVariant,
            backgroundColor: selected
                ? colors.surfaceContainerLow
                : Colors.transparent,
            textStyle: theme.textTheme.labelLarge?.copyWith(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: Text(strings(label), textAlign: TextAlign.center),
        ),
      ),
    );
  }
}
