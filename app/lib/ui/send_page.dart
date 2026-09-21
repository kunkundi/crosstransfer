// Send page: drop zone + list of share cards (QR, link, code, progress).
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
import '../platform/mobile.dart';
import '../state/format.dart';
import '../state/models.dart';
import '../state/providers.dart';
import 'widgets.dart';

class SendPage extends ConsumerStatefulWidget {
  const SendPage({super.key});

  @override
  ConsumerState<SendPage> createState() => _SendPageState();
}

class _SendPageState extends ConsumerState<SendPage> {
  bool _dragging = false;

  Future<void> _share(List<String> paths) async {
    final cleaned = paths.where((e) => e.isNotEmpty).toSet().toList();
    if (cleaned.isEmpty) return;
    final s = ref.read(sProvider);
    final state = ref.read(coreStateProvider);
    if (!state.serverConfigured) {
      showSnack(context, s('send.no_server'));
      return;
    }
    try {
      ref.read(coreStateProvider.notifier).createShare(cleaned);
    } on CoreException catch (e) {
      if (mounted) showSnack(context, '${s('send.share_failed')} (${e.status})');
    }
  }

  Future<void> _pickFiles() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: ref.read(sProvider)('send.pick_files'),
    );
    final paths = files.map((f) => f.path).whereType<String>().toList();
    await _share(paths);
  }

  Future<void> _pickFolder() async {
    final dir = await FilePicker.getDirectoryPath(
        dialogTitle: ref.read(sProvider)('send.pick_folder'));
    if (dir != null) await _share([dir]);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sProvider);
    final shares = ref.watch(coreStateProvider.select((st) => st.shareList));
    final theme = Theme.of(context);
    final compact = shares.isNotEmpty;

    final content = ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _DropZone(
            active: _dragging,
            compact: compact,
            onPickFiles: _pickFiles,
            onPickFolder: _pickFolder,
          ),
          if (shares.isEmpty)
            EmptyHint(s(MobilePlatform.isMobile ? 'send.mobile_empty' : 'send.empty'))
          else ...[
            const SizedBox(height: 16),
            for (final share in shares)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _ShareCard(share: share, key: ValueKey(share.id)),
              ),
          ],
          if (!ref.watch(coreStateProvider.select((st) => st.serverConfigured)))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(s('send.no_server'),
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
    );
    if (MobilePlatform.isMobile) return content;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) {
        setState(() => _dragging = false);
        _share(d.files.map((f) => f.path).toList());
      },
      child: content,
    );
  }
}

class _DropZone extends ConsumerWidget {
  const _DropZone({
    required this.active,
    required this.compact,
    required this.onPickFiles,
    required this.onPickFolder,
  });

  final bool active;
  final bool compact;
  final VoidCallback onPickFiles;
  final VoidCallback onPickFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final cs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: compact ? 120 : 260,
      decoration: BoxDecoration(
        color: active ? cs.primaryContainer.withValues(alpha: 0.5) : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: active ? cs.primary : cs.outlineVariant,
          width: active ? 2 : 1,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(active ? Icons.file_download_outlined : Icons.upload_file_outlined,
              size: compact ? 28 : 48, color: cs.primary),
          const SizedBox(height: 8),
          Text(active ? s('send.drop_active') : s(MobilePlatform.isMobile ? 'send.pick_files' : 'send.drop_hint'),
              style: Theme.of(context).textTheme.titleMedium),
          if (!active) ...[
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: onPickFiles,
                  icon: const Icon(Icons.insert_drive_file_outlined),
                  label: Text(s('send.pick_files')),
                ),
                if (!MobilePlatform.isIOS) FilledButton.tonalIcon(
                  onPressed: onPickFolder,
                  icon: const Icon(Icons.folder_outlined),
                  label: Text(s('send.pick_folder')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ShareCard extends ConsumerStatefulWidget {
  const _ShareCard({required this.share, super.key});
  final ShareInfo share;

  @override
  ConsumerState<_ShareCard> createState() => _ShareCardState();
}

class _ShareCardState extends ConsumerState<_ShareCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.share.isActive) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _copy(String text, String toast) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showSnack(context, toast);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sProvider);
    final share = widget.share;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final transfers = ref.watch(
        coreStateProvider.select((st) => st.transfersForShare(share.id)));
    final live = transfers.where((t) => !t.isTerminal).toList();
    final title = share.paths.isNotEmpty
        ? share.paths.map((e) => p.basename(e)).join(', ')
        : (share.code.isEmpty ? share.id : share.code);
    final remaining = share.expiresAt > 0 ? secondsUntil(share.expiresAt) : -1;
    final ready = share.state == 'ready' || share.state == 'claimed' ||
        share.state == 'transferring';

    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: theme.textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text(
                        s('send.files_bytes')
                            .replaceFirst('{files}', '${share.files}')
                            .replaceFirst('{bytes}', formatBytes(share.bytes)),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                StateChip(share.state,
                    detail: share.state == 'failed' || share.state == 'closed'
                        ? s.errorCode(share.error)
                        : null),
                const SizedBox(width: 8),
                if (share.isActive)
                  IconButton(
                    tooltip: s('send.close'),
                    onPressed: () =>
                        ref.read(coreStateProvider.notifier).closeShare(share.id),
                    icon: const Icon(Icons.close),
                  )
                else
                  IconButton(
                    tooltip: s('send.remove'),
                    onPressed: () =>
                        ref.read(coreStateProvider.notifier).removeShare(share.id),
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
            if (share.state == 'creating')
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Row(children: [
                  const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Text(s('send.creating')),
                ]),
              ),
            if (ready && share.link.isNotEmpty) ...[
              const SizedBox(height: 16),
              LayoutBuilder(builder: (context, c) {
                final narrow = c.maxWidth < 560;
                final qr = Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: share.link,
                    size: 168,
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.white,
                  ),
                );
                final info = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(share.link,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()])),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      FilledButton.icon(
                        onPressed: () => _copy(share.link, s('send.copied')),
                        icon: const Icon(Icons.link),
                        label: Text(s('send.copy_link')),
                      ),
                      if (MobilePlatform.isIOS)
                        OutlinedButton.icon(
                          onPressed: () => MobilePlatform.shareLink(share.link),
                          icon: const Icon(Icons.ios_share),
                          label: Text(s('send.system_share')),
                        ),
                      OutlinedButton.icon(
                        onPressed: () => _copy(share.code, s('send.copied')),
                        icon: const Icon(Icons.pin_outlined),
                        label: Text(s('send.copy_code')),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    Text(s('send.code_label'),
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: cs.onSurfaceVariant)),
                    SelectableText(share.code,
                        style: theme.textTheme.headlineSmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            letterSpacing: 2)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 12, children: [
                      Text(s('send.mode.${share.mode}'),
                          style: theme.textTheme.bodySmall),
                      if (remaining >= 0)
                        Text(
                          remaining > 0
                              ? '${s('send.expires_in')} ${formatCountdown(remaining)}'
                              : s('send.expired'),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: remaining < 60 ? cs.error : null),
                        ),
                      if (share.mode == 'open' || share.completed > 0)
                        Text(s('send.receivers').replaceFirst('{n}', '${share.completed}'),
                            style: theme.textTheme.bodySmall),
                    ]),
                  ],
                );
                if (narrow) {
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Center(child: qr),
                    const SizedBox(height: 16),
                    info,
                  ]);
                }
                return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  qr,
                  const SizedBox(width: 24),
                  Expanded(child: info),
                ]);
              }),
            ],
            if (share.state == 'ready' && live.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(children: [
                  const SizedBox(
                      width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text(s('send.waiting'), style: theme.textTheme.bodySmall),
                ]),
              ),
            for (final t in live) ...[
              const SizedBox(height: 16),
              Row(children: [
                Icon(Icons.swap_vert, size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(s.state(t.state), style: theme.textTheme.labelMedium),
                if (t.currentFile >= 0 && t.filesTotal > 0)
                  Text('  ·  ${t.currentFile + 1}/${t.filesTotal}',
                      style: theme.textTheme.labelMedium),
              ]),
              const SizedBox(height: 6),
              TransferProgressView(t),
            ],
          ],
        ),
      ),
    );
  }
}
