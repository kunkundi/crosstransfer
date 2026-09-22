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
    if (!state.serviceAvailable) {
      showSnack(context, s('service.unavailable'));
      return;
    }
    try {
      ref.read(coreStateProvider.notifier).createShare(cleaned);
    } on CoreException catch (e) {
      if (mounted) {
        showSnack(context, '${s('send.share_failed')} (${e.status})');
      }
    }
  }

  Future<void> _pickFiles() async {
    if (MobilePlatform.isAndroid) {
      await _pickAndroid();
      return;
    }
    final files = await FilePicker.pickFiles(
      dialogTitle: ref.read(sProvider)('send.pick_files'),
    );
    final paths = files.map((f) => f.path).whereType<String>().toList();
    await _share(paths);
  }

  Future<void> _pickFolder() async {
    if (MobilePlatform.isAndroid) {
      await _pickAndroid(folder: true);
      return;
    }
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: ref.read(sProvider)('send.pick_folder'),
    );
    if (dir != null) await _share([dir]);
  }

  Future<void> _pickAndroid({bool folder = false}) async {
    try {
      final paths = await MobilePlatform.pickAndroidFiles(folder: folder);
      if (mounted) await _share(paths);
    } catch (e) {
      if (mounted) {
        showSnack(context, '${ref.read(sProvider)('common.error')}: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sProvider);
    final shares = ref.watch(coreStateProvider.select((st) => st.shareList));
    final theme = Theme.of(context);
    final compact = shares.isNotEmpty;
    final mobile = MediaQuery.sizeOf(context).width < 600;

    final content = ListView(
      padding: EdgeInsets.fromLTRB(
        mobile ? 16 : 24,
        mobile ? 26 : 20,
        mobile ? 16 : 24,
        mobile ? 32 : 24,
      ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PageHeader(
                  title: s('send.title'),
                  subtitle: s('send.subtitle'),
                ),
                _DropZone(
                  active: _dragging,
                  compact: compact,
                  onPickFiles: _pickFiles,
                  onPickFolder: _pickFolder,
                ),
                if (shares.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(
                    s('send.active_shares'),
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  for (final share in shares)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _ShareCard(share: share, key: ValueKey(share.id)),
                    ),
                ],
                if (!ref.watch(
                  coreStateProvider.select((st) => st.serviceAvailable),
                ))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.cloud_off_outlined,
                          size: 18,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            s('service.unavailable'),
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final narrow = MediaQuery.sizeOf(context).width < 460;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      constraints: BoxConstraints(
        minHeight: compact ? (narrow ? 188 : 124) : (narrow ? 292 : 186),
      ),
      decoration: BoxDecoration(
        color: active
            ? cs.primaryContainer.withValues(alpha: 0.72)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: active ? cs.primary : cs.outlineVariant,
          width: active ? 2 : 1,
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: cs.primary.withValues(alpha: 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: compact ? 38 : (narrow ? 56 : 46),
              height: compact ? 38 : (narrow ? 56 : 46),
              decoration: BoxDecoration(
                color: active ? cs.primary : cs.primaryContainer,
                borderRadius: BorderRadius.circular(compact ? 13 : 17),
              ),
              child: Icon(
                active
                    ? Icons.file_download_outlined
                    : Icons.upload_file_rounded,
                size: compact ? 22 : (narrow ? 29 : 25),
                color: active ? cs.onPrimary : cs.onPrimaryContainer,
              ),
            ),
            SizedBox(height: compact ? 6 : (narrow ? 12 : 8)),
            Text(
              active
                  ? s('send.drop_active')
                  : s(
                      MobilePlatform.isMobile
                          ? 'send.pick_files'
                          : 'send.drop_hint',
                    ),
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (!active) ...[
              if (!compact) ...[
                const SizedBox(height: 4),
                Text(
                  s('send.secure_hint'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
              SizedBox(height: compact ? 8 : (narrow ? 16 : 11)),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: onPickFiles,
                    icon: const Icon(
                      Icons.insert_drive_file_outlined,
                      size: 19,
                    ),
                    label: Text(s('send.pick_files')),
                  ),
                  if (!MobilePlatform.isIOS)
                    OutlinedButton.icon(
                      onPressed: onPickFolder,
                      icon: const Icon(Icons.folder_outlined, size: 19),
                      label: Text(s('send.pick_folder')),
                    ),
                ],
              ),
            ],
          ],
        ),
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
      coreStateProvider.select((st) => st.transfersForShare(share.id)),
    );
    final live = transfers.where((t) => !t.isTerminal).toList();
    final title = share.paths.isNotEmpty
        ? share.paths.map((e) => p.basename(e)).join(', ')
        : (share.code.isEmpty ? share.id : share.code);
    final remaining = share.expiresAt > 0 ? secondsUntil(share.expiresAt) : -1;
    final ready =
        share.state == 'ready' ||
        share.state == 'claimed' ||
        share.state == 'transferring';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    share.files > 1
                        ? Icons.folder_copy_outlined
                        : Icons.insert_drive_file_outlined,
                    size: 21,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        s('send.files_bytes')
                            .replaceFirst('{files}', '${share.files}')
                            .replaceFirst('{bytes}', formatBytes(share.bytes)),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                StateChip(
                  share.state,
                  detail: share.state == 'failed' || share.state == 'closed'
                      ? s.errorCode(share.error)
                      : null,
                ),
                const SizedBox(width: 8),
                if (share.isActive)
                  IconButton(
                    tooltip: s('send.close'),
                    onPressed: () => ref
                        .read(coreStateProvider.notifier)
                        .closeShare(share.id),
                    icon: const Icon(Icons.close),
                  )
                else
                  IconButton(
                    tooltip: s('send.remove'),
                    onPressed: () => ref
                        .read(coreStateProvider.notifier)
                        .removeShare(share.id),
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
            if (share.state == 'creating')
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Text(s('send.creating')),
                  ],
                ),
              ),
            if (ready && share.link.isNotEmpty) ...[
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (context, c) {
                  final narrow = c.maxWidth < 560;
                  final qr = Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: cs.outlineVariant),
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
                      Text(
                        s('send.code_label'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 3),
                      SelectableText(
                        share.code,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          letterSpacing: 2.4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: () =>
                                _copy(share.code, s('send.copied')),
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            label: Text(s('send.copy_code')),
                          ),
                          if (MobilePlatform.isMobile)
                            OutlinedButton.icon(
                              onPressed: () =>
                                  MobilePlatform.shareLink(share.link),
                              icon: const Icon(Icons.ios_share, size: 18),
                              label: Text(s('send.system_share')),
                            ),
                          OutlinedButton.icon(
                            onPressed: () =>
                                _copy(share.link, s('send.copied')),
                            icon: const Icon(Icons.link_rounded, size: 18),
                            label: Text(s('send.copy_link')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: SelectableText(
                          share.link,
                          maxLines: 2,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 12,
                        children: [
                          Text(
                            s('send.mode.${share.mode}'),
                            style: theme.textTheme.bodySmall,
                          ),
                          if (remaining >= 0)
                            Text(
                              remaining > 0
                                  ? '${s('send.expires_in')} ${formatCountdown(remaining)}'
                                  : s('send.expired'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: remaining < 60 ? cs.error : null,
                              ),
                            ),
                          if (share.mode == 'open' || share.completed > 0)
                            Text(
                              s('send.receivers')
                                  .replaceFirst('{n}', '${share.completed}'),
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ],
                  );
                  if (narrow) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(child: qr),
                        const SizedBox(height: 16),
                        info,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      qr,
                      const SizedBox(width: 24),
                      Expanded(child: info),
                    ],
                  );
                },
              ),
            ],
            if (share.state == 'ready' && live.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(s('send.waiting'), style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            for (final t in live) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(Icons.swap_vert, size: 16, color: cs.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(s.state(t.state), style: theme.textTheme.labelMedium),
                  if (t.currentFile >= 0 && t.filesTotal > 0)
                    Text(
                      '  ·  ${t.currentFile + 1}/${t.filesTotal}',
                      style: theme.textTheme.labelMedium,
                    ),
                ],
              ),
              const SizedBox(height: 6),
              TransferProgressView(t),
            ],
          ],
        ),
      ),
    );
  }
}
