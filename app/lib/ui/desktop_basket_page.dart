// Cross-platform compact quick-send basket for desktop.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../ffi/core_client.dart';
import '../platform/desktop_basket.dart';
import '../state/models.dart';
import '../state/providers.dart';

class DesktopBasketPage extends ConsumerStatefulWidget {
  const DesktopBasketPage({super.key});

  @override
  ConsumerState<DesktopBasketPage> createState() => _DesktopBasketPageState();
}

class _DesktopBasketPageState extends ConsumerState<DesktopBasketPage> {
  bool _dragging = false;
  String? _lastShareId;
  List<String> _pendingPaths = const [];
  String? _error;
  String? _confirmation;

  void _share(List<String> paths) {
    final cleaned = paths.where((path) => path.isNotEmpty).toSet().toList();
    if (cleaned.isEmpty) return;
    setState(() {
      _dragging = false;
      _pendingPaths = cleaned;
      _lastShareId = null;
      _error = null;
      _confirmation = null;
    });
    final state = ref.read(coreStateProvider);
    if (!state.serviceAvailable) {
      setState(() => _error = ref.read(sProvider)('service.unavailable'));
      return;
    }
    try {
      final id = ref.read(coreStateProvider.notifier).createShare(cleaned);
      setState(() {
        _lastShareId = id;
        _pendingPaths = const [];
      });
    } on CoreException catch (error) {
      setState(() {
        _error =
            '${ref.read(sProvider)('send.share_failed')} (${error.status})';
      });
    }
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: ref.read(sProvider)('send.pick_files'),
    );
    if (!mounted) return;
    _share(result.map((file) => file.path).whereType<String>().toList());
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: ref.read(sProvider)('send.pick_folder'),
    );
    if (mounted && path != null) _share([path]);
  }

  Future<void> _copy(String value) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      setState(() => _confirmation = ref.read(sProvider)('send.copied'));
    }
  }

  void _reset() {
    setState(() {
      _lastShareId = null;
      _pendingPaths = const [];
      _error = null;
      _confirmation = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(coreStateProvider);
    final share = _lastShareId == null ? null : state.shares[_lastShareId];
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: colorScheme.surface,
      child: Column(
        children: [
          const _BasketHeader(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: DropTarget(
                onDragEntered: (_) => setState(() => _dragging = true),
                onDragExited: (_) => setState(() => _dragging = false),
                onDragDone: (details) =>
                    _share(details.files.map((file) => file.path).toList()),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: _dragging
                        ? colorScheme.primaryContainer.withValues(alpha: 0.7)
                        : colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _dragging
                          ? colorScheme.primary
                          : colorScheme.outlineVariant,
                      width: _dragging ? 2 : 1,
                    ),
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 140),
                    child: _dragging
                        ? _ActiveDropHint(key: const ValueKey('dragging'))
                        : _content(state, share),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(CoreState state, ShareInfo? share) {
    if (_pendingPaths.isNotEmpty) {
      return _PendingSelection(
        key: const ValueKey('pending'),
        paths: _pendingPaths,
        error: _error,
        canRetry: state.serviceAvailable,
        onRetry: () => _share(_pendingPaths),
        onClear: _reset,
      );
    }
    if (_lastShareId != null) {
      return _ShareResult(
        key: const ValueKey('result'),
        share: share,
        confirmation: _confirmation,
        onCopyCode: () => _copy(share?.code ?? ''),
        onCopyLink: () => _copy(share?.link ?? ''),
        onAgain: _reset,
      );
    }
    return _EmptyBasket(
      key: const ValueKey('empty'),
      serviceAvailable: state.serviceAvailable,
      onPickFiles: _pickFiles,
      onPickFolder: _pickFolder,
    );
  }
}

class _BasketHeader extends ConsumerWidget {
  const _BasketHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Row(
                    children: [
                      Icon(
                        Icons.move_to_inbox_outlined,
                        size: 20,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        s('basket.title'),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: s('basket.open_main'),
            onPressed: DesktopBasket.instance.showMain,
            icon: const Icon(Icons.open_in_full, size: 18),
          ),
          ListenableBuilder(
            listenable: DesktopBasket.instance,
            builder: (context, _) {
              final pinned = DesktopBasket.instance.pinned;
              return IconButton(
                key: const Key('basket-pin-toggle'),
                tooltip: s(pinned ? 'basket.unpin' : 'basket.pin'),
                isSelected: pinned,
                selectedIcon: const Icon(Icons.push_pin, size: 18),
                style: IconButton.styleFrom(
                  backgroundColor: pinned
                      ? colors.primaryContainer
                      : Colors.transparent,
                  foregroundColor: pinned
                      ? colors.onPrimaryContainer
                      : colors.onSurfaceVariant,
                ),
                onPressed: DesktopBasket.instance.togglePinned,
                icon: const Icon(Icons.push_pin_outlined, size: 18),
              );
            },
          ),
          IconButton(
            tooltip: s('basket.hide'),
            onPressed: DesktopBasket.instance.hide,
            icon: const Icon(Icons.close, size: 19),
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

class _ActiveDropHint extends ConsumerWidget {
  const _ActiveDropHint({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.file_download_outlined, size: 48, color: colors.primary),
          const SizedBox(height: 10),
          Text(
            ref.watch(sProvider)('send.drop_active'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

class _EmptyBasket extends ConsumerWidget {
  const _EmptyBasket({
    super.key,
    required this.serviceAvailable,
    required this.onPickFiles,
    required this.onPickFolder,
  });

  final bool serviceAvailable;
  final VoidCallback onPickFiles;
  final VoidCallback onPickFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.upload_file_outlined, size: 40, color: colors.primary),
          const SizedBox(height: 8),
          Text(
            s('basket.drop_hint'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: onPickFiles,
                  icon: const Icon(Icons.insert_drive_file_outlined, size: 18),
                  label: Text(s('send.pick_files')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: onPickFolder,
                  icon: const Icon(Icons.folder_outlined, size: 18),
                  label: Text(s('send.pick_folder')),
                ),
              ),
            ],
          ),
          if (!serviceAvailable) ...[
            const SizedBox(height: 8),
            Text(
              s('service.unavailable'),
              style: TextStyle(color: colors.error, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _PendingSelection extends ConsumerWidget {
  const _PendingSelection({
    super.key,
    required this.paths,
    required this.error,
    required this.canRetry,
    required this.onRetry,
    required this.onClear,
  });

  final List<String> paths;
  final String? error;
  final bool canRetry;
  final VoidCallback onRetry;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.inventory_2_outlined, size: 34, color: colors.primary),
          const SizedBox(height: 8),
          Text(
            _pathSummary(paths),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          if (error != null) ...[
            const SizedBox(height: 7),
            Text(
              error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.error, fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton(
                onPressed: canRetry ? onRetry : null,
                child: Text(s('basket.retry')),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: onClear, child: Text(s('common.cancel'))),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShareResult extends ConsumerWidget {
  const _ShareResult({
    super.key,
    required this.share,
    required this.confirmation,
    required this.onCopyCode,
    required this.onCopyLink,
    required this.onAgain,
  });

  final ShareInfo? share;
  final String? confirmation;
  final VoidCallback onCopyCode;
  final VoidCallback onCopyLink;
  final VoidCallback onAgain;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final colors = Theme.of(context).colorScheme;
    if (share == null || (share!.code.isEmpty && share!.state != 'failed')) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(s('send.creating')),
        ],
      );
    }
    if (share!.state == 'failed') {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: colors.error, size: 36),
            const SizedBox(height: 8),
            Text(s('send.share_failed'), style: TextStyle(color: colors.error)),
            if (share!.error.isNotEmpty) Text(s.errorCode(share!.error)),
            const SizedBox(height: 10),
            TextButton(onPressed: onAgain, child: Text(s('basket.try_again'))),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _pathSummary(share!.paths),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 5),
          SelectableText(
            share!.code,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: colors.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
          if (confirmation != null)
            Text(confirmation!, style: TextStyle(color: colors.primary)),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            children: [
              FilledButton.tonalIcon(
                onPressed: onCopyCode,
                icon: const Icon(Icons.copy, size: 17),
                label: Text(s('send.copy_code')),
              ),
              if (share!.link.isNotEmpty)
                FilledButton.tonalIcon(
                  onPressed: onCopyLink,
                  icon: const Icon(Icons.link, size: 17),
                  label: Text(s('send.copy_link')),
                ),
              TextButton(onPressed: onAgain, child: Text(s('basket.again'))),
            ],
          ),
        ],
      ),
    );
  }
}

String _pathSummary(List<String> paths) {
  if (paths.isEmpty) return '';
  final names = paths.take(2).map(p.basename).join(', ');
  return paths.length > 2 ? '$names +${paths.length - 2}' : names;
}
