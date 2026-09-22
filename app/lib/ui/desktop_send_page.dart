// Compact desktop sending, with access to all existing shares.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../ffi/core_client.dart';
import '../state/models.dart';
import '../state/providers.dart';
import 'send_page.dart';

class DesktopSendPage extends ConsumerStatefulWidget {
  const DesktopSendPage({super.key});

  @override
  ConsumerState<DesktopSendPage> createState() => _DesktopSendPageState();
}

class _DesktopSendPageState extends ConsumerState<DesktopSendPage> {
  bool _dragging = false;
  bool _showHistory = false;
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

    if (_showHistory) {
      return Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _showHistory = false),
              icon: const Icon(Icons.arrow_back_rounded, size: 16),
              label: Text(ref.watch(sProvider)('send.new_share')),
            ),
          ),
          const Expanded(child: SendPage(historyOnly: true)),
        ],
      );
    }
    return Material(
      color: colorScheme.surface,
      child: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
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
                    borderRadius: BorderRadius.circular(12),
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
          if (state.shares.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => _showHistory = true),
              child: Text(
                '${ref.watch(sProvider)('send.history')} · ${state.shares.length}',
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
    if (_lastShareId != null && share != null) {
      return _ShareResult(
        key: const ValueKey('result'),
        share: share,
        confirmation: _confirmation,
        onCopyCode: () => _copy(share.code),
        onCopyLink: () => _copy(share.link),
        onAgain: _reset,
      );
    }
    return _EmptySend(
      key: const ValueKey('empty'),
      serviceAvailable: state.serviceAvailable,
      onPickFiles: _pickFiles,
      onPickFolder: _pickFolder,
    );
  }
}

class _ActiveDropHint extends ConsumerWidget {
  const _ActiveDropHint({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    return _SendBody(
      children: [
        Icon(Icons.file_download_outlined, size: 36, color: colors.primary),
        const SizedBox(height: 12),
        Text(
          ref.watch(sProvider)('send.drop_active'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    );
  }
}

class _EmptySend extends ConsumerWidget {
  const _EmptySend({
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
    return _SendBody(
      children: [
        Center(
          child: Container(
            width: 44,
            height: 48,
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(
              Icons.upload_file_outlined,
              size: 29,
              color: colors.primary,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          s('send.drop_hint'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: onPickFiles,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(s('send.pick_files')),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onPickFolder,
          icon: const Icon(Icons.folder_outlined, size: 18),
          label: Text(s('send.pick_folder')),
        ),
        if (!serviceAvailable) ...[
          const SizedBox(height: 12),
          Text(
            s('service.unavailable'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.error),
          ),
        ],
      ],
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
    return _SendBody(
      children: [
        Icon(Icons.inventory_2_outlined, size: 32, color: colors.primary),
        const SizedBox(height: 12),
        Text(
          _pathSummary(paths),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(
            error!,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.error),
          ),
        ],
        const SizedBox(height: 18),
        FilledButton(
          onPressed: canRetry ? onRetry : null,
          child: Text(s('send.retry')),
        ),
        const SizedBox(height: 6),
        TextButton(onPressed: onClear, child: Text(s('common.cancel'))),
      ],
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
    final theme = Theme.of(context);
    if (share == null || (share!.code.isEmpty && share!.isActive)) {
      return _SendBody(
        children: [
          const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          const SizedBox(height: 14),
          Text(s('send.creating'), textAlign: TextAlign.center),
        ],
      );
    }
    if (share!.state == 'failed') {
      return _SendBody(
        children: [
          Icon(Icons.error_outline, color: colors.error, size: 32),
          const SizedBox(height: 12),
          Text(
            s('send.share_failed'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(color: colors.error),
          ),
          if (share!.error.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(s.errorCode(share!.error), textAlign: TextAlign.center),
          ],
          const SizedBox(height: 18),
          OutlinedButton(onPressed: onAgain, child: Text(s('send.try_again'))),
        ],
      );
    }
    if (!share!.isActive) {
      return _SendBody(
        children: [
          Icon(
            share!.state == 'completed'
                ? Icons.check_circle_outline
                : Icons.cancel_outlined,
            size: 32,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            s.state(share!.state),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 18),
          FilledButton(onPressed: onAgain, child: Text(s('send.again'))),
        ],
      );
    }
    return _SendBody(
      children: [
        Text(
          _pathSummary(share!.paths),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '${s('send.code_label')} · ${s.state(share!.state)}',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium,
        ),
        const SizedBox(height: 4),
        SelectableText(
          share!.code,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontSize: 22,
            color: colors.primary,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
            letterSpacing: 1,
          ),
        ),
        if (confirmation != null) ...[
          const SizedBox(height: 4),
          Semantics(
            liveRegion: true,
            child: Text(
              confirmation!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.primary),
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onCopyCode,
          icon: const Icon(Icons.copy, size: 16),
          label: Text(s('send.copy_code')),
        ),
        if (share!.link.isNotEmpty) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onCopyLink,
            icon: const Icon(Icons.link, size: 18),
            label: Text(s('send.copy_link')),
          ),
        ],
        const SizedBox(height: 6),
        TextButton(onPressed: onAgain, child: Text(s('send.again'))),
      ],
    );
  }
}

// Keep every state in the same single column. Large text and longer localized
// messages can scroll without clipping the actions in the compact window.
class _SendBody extends StatelessWidget {
  const _SendBody({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

String _pathSummary(List<String> paths) {
  if (paths.isEmpty) return '';
  final names = paths.take(2).map(p.basename).join(', ');
  return paths.length > 2 ? '$names +${paths.length - 2}' : names;
}
