// Compact desktop sending, with access to all existing shares.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';

import '../ffi/core_client.dart';
import '../state/format.dart';
import '../state/models.dart';
import '../state/providers.dart';
import 'send_page.dart';
import 'widgets.dart';

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

  void _share(List<String> paths) {
    final cleaned = paths.where((path) => path.isNotEmpty).toSet().toList();
    if (cleaned.isEmpty) return;
    setState(() {
      _dragging = false;
      _pendingPaths = cleaned;
      _lastShareId = null;
      _error = null;
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

  void _reset() {
    setState(() {
      _lastShareId = null;
      _pendingPaths = const [];
      _error = null;
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
      color: Theme.of(context).scaffoldBackgroundColor,
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
        Icon(
          Icons.file_copy_outlined,
          size: 36,
          color: colors.onSurfaceVariant.withValues(alpha: 0.6),
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
        Text(_pathSummary(paths), textAlign: TextAlign.center),
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

class _ShareResult extends ConsumerStatefulWidget {
  const _ShareResult({super.key, required this.share, required this.onAgain});

  final ShareInfo share;
  final VoidCallback onAgain;

  @override
  ConsumerState<_ShareResult> createState() => _ShareResultState();
}

class _ShareResultState extends ConsumerState<_ShareResult> {
  Timer? _copyReset;
  String? _copied;

  @override
  void didUpdateWidget(covariant _ShareResult oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.share.id != widget.share.id) {
      _copyReset?.cancel();
      _copied = null;
    }
  }

  @override
  void dispose() {
    _copyReset?.cancel();
    super.dispose();
  }

  Future<void> _copy(String kind, String value) async {
    final id = widget.share.id;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted || widget.share.id != id) return;
    _copyReset?.cancel();
    setState(() => _copied = kind);
    _copyReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final share = widget.share;
    final s = ref.watch(sProvider);
    final colors = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final transfers = ref.watch(
      coreStateProvider.select(
        (state) => state.transfersForShare(widget.share.id),
      ),
    )..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final live = transfers.where((transfer) => !transfer.isTerminal).toList();
    final visibleTransfers = live.isNotEmpty ? live : transfers.take(1);
    if (share.code.isEmpty && share.isActive) {
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
    if (share.state == 'failed') {
      return _SendBody(
        children: [
          Icon(Icons.error_outline, color: colors.error, size: 32),
          const SizedBox(height: 12),
          Text(
            s('send.share_failed'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(color: colors.error),
          ),
          if (share.error.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(s.errorCode(share.error), textAlign: TextAlign.center),
          ],
          const SizedBox(height: 18),
          OutlinedButton(
            onPressed: widget.onAgain,
            child: Text(s('send.try_again')),
          ),
        ],
      );
    }
    if (!share.isActive) {
      return _SendBody(
        children: [
          Icon(
            share.state == 'completed'
                ? Icons.check_circle_outline
                : Icons.cancel_outlined,
            size: 32,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            s.state(share.state),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 18),
          FilledButton(onPressed: widget.onAgain, child: Text(s('send.again'))),
        ],
      );
    }
    return _SendBody(
      children: [
        Text(
          _pathSummary(share.paths),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        for (final transfer in visibleTransfers) ...[
          const SizedBox(height: 10),
          _SendingProgress(transfer: transfer),
        ],
        const SizedBox(height: 12),
        Text(
          '${s('send.code_label')} · ${s.state(share.state)}',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium,
        ),
        const SizedBox(height: 4),
        SelectableText(
          share.code,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontSize: 22,
            color: colors.primary,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 8),
        _ShareClock(
          expiresAt: share.expiresAt,
          builder: (context, remaining) {
            final expired = remaining != null && remaining <= 0;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (remaining != null) ...[
                  Text(
                    expired
                        ? s('send.expired')
                        : '${s('send.expires_in')} ${formatCountdown(remaining)}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: remaining < 60
                          ? colors.error
                          : colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                FilledButton.icon(
                  key: const Key('share-copy-code'),
                  onPressed: expired ? null : () => _copy('code', share.code),
                  icon: Icon(
                    _copied == 'code' ? Icons.check : Icons.copy,
                    size: 16,
                  ),
                  label: _CopyLabel(
                    label: s('send.copy_code'),
                    confirmation: _copied == 'code' ? s('send.copied') : null,
                  ),
                ),
                if (share.link.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 4,
                    children: [
                      TextButton.icon(
                        key: const Key('share-copy-link'),
                        onPressed: expired
                            ? null
                            : () => _copy('link', share.link),
                        icon: Icon(
                          _copied == 'link' ? Icons.check : Icons.link,
                          size: 16,
                        ),
                        label: _CopyLabel(
                          label: s('send.copy_link'),
                          confirmation: _copied == 'link'
                              ? s('send.copied')
                              : null,
                        ),
                      ),
                      TextButton.icon(
                        key: const Key('share-show-qr'),
                        onPressed: expired
                            ? null
                            : () => showDialog<void>(
                                context: context,
                                builder: (_) =>
                                    _ShareQrDialog(shareId: share.id),
                              ),
                        icon: const Icon(Icons.qr_code, size: 16),
                        label: Text(s('send.qr')),
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 6),
        TextButton(onPressed: widget.onAgain, child: Text(s('send.again'))),
      ],
    );
  }
}

class _CopyLabel extends StatelessWidget {
  const _CopyLabel({required this.label, required this.confirmation});
  final String label;
  final String? confirmation;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: confirmation ?? label,
    excludeSemantics: true,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Opacity(opacity: confirmation == null ? 1 : 0, child: Text(label)),
        if (confirmation != null)
          Positioned.fill(child: Center(child: Text(confirmation!))),
      ],
    ),
  );
}

class _SendingProgress extends ConsumerWidget {
  const _SendingProgress({required this.transfer});
  final TransferInfo transfer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final theme = Theme.of(context);
    return Column(
      key: ValueKey('sending-${transfer.transferId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                s.state(transfer.state),
                style: theme.textTheme.labelMedium,
              ),
            ),
            Text(
              formatPercent(transfer.fraction),
              style: theme.textTheme.labelMedium,
            ),
            if (!transfer.isTerminal)
              IconButton(
                key: ValueKey('cancel-${transfer.transferId}'),
                tooltip: s('recv.cancel'),
                onPressed: () => ref
                    .read(coreStateProvider.notifier)
                    .cancelTransfer(transfer.transferId),
                icon: const Icon(Icons.close, size: 16),
              ),
          ],
        ),
        LinearProgressIndicator(
          value: transfer.bytesTotal > 0
              ? transfer.fraction
              : (transfer.isTerminal ? 0 : null),
          color: stateColor(context, transfer.state),
        ),
        const SizedBox(height: 5),
        Text(
          '${formatBytes(transfer.bytesDone)} / ${formatBytes(transfer.bytesTotal)}',
          style: theme.textTheme.bodySmall,
        ),
        if (!transfer.isTerminal)
          Wrap(
            spacing: 12,
            children: [
              Text(
                formatRate(transfer.rateBps),
                style: theme.textTheme.bodySmall,
              ),
              Text(
                '${s('recv.eta')} ${formatEta(transfer.etaSec)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        if (transfer.state == 'failed' && transfer.errorCode.isNotEmpty)
          Text(
            s.errorCode(transfer.errorCode),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
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

// Keep expiry local to the code controls: it must not interrupt an active transfer.
class _ShareClock extends StatefulWidget {
  const _ShareClock({required this.expiresAt, required this.builder});
  final int expiresAt;
  final Widget Function(BuildContext, int?) builder;

  @override
  State<_ShareClock> createState() => _ShareClockState();
}

class _ShareClockState extends State<_ShareClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startClock();
  }

  @override
  void didUpdateWidget(covariant _ShareClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expiresAt != widget.expiresAt) _startClock();
  }

  void _startClock() {
    _timer?.cancel();
    if (widget.expiresAt <= 0 || secondsUntil(widget.expiresAt) <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (secondsUntil(widget.expiresAt) <= 0) timer.cancel();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    widget.expiresAt > 0 ? secondsUntil(widget.expiresAt) : null,
  );
}

class _ShareQrDialog extends ConsumerWidget {
  const _ShareQrDialog({required this.shareId});
  final String shareId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final share = ref.watch(
      coreStateProvider.select((state) => state.shares[shareId]),
    );
    return AlertDialog(
      title: Text(s('send.qr')),
      content: _ShareClock(
        expiresAt: share?.expiresAt ?? 0,
        builder: (context, remaining) {
          final available =
              share != null &&
              share.isActive &&
              share.link.isNotEmpty &&
              (remaining == null || remaining > 0);
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (available)
                  Semantics(
                    label: s('send.qr'),
                    child: SizedBox.square(
                      dimension: 190,
                      child: QrImageView(
                        data: share.link,
                        size: 190,
                        padding: const EdgeInsets.all(12),
                        backgroundColor: Colors.white,
                      ),
                    ),
                  )
                else
                  Text(
                    s(
                      remaining != null && remaining <= 0
                          ? 'send.expired'
                          : 'send.unavailable',
                    ),
                  ),
                if (available) ...[
                  const SizedBox(height: 8),
                  SelectableText(share.code, textAlign: TextAlign.center),
                ],
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s('common.close')),
        ),
      ],
    );
  }
}
