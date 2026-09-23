// Receive page: link / code input, save folder, list of receives.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../ffi/core_client.dart';
import '../platform/mobile.dart';
import 'scan_page.dart';
import '../state/format.dart';
import '../state/models.dart';
import '../state/providers.dart';
import 'widgets.dart';
import 'theme.dart';

class ReceivePage extends ConsumerStatefulWidget {
  const ReceivePage({super.key});

  @override
  ConsumerState<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends ConsumerState<ReceivePage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  String? _saveDirOverride;
  String? _error;

  @override
  void initState() {
    super.initState();
    _input.addListener(() => setState(() => _error = null));
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _saveDir =>
      _saveDirOverride ?? ref.read(coreStateProvider).config.saveDir;

  Future<void> _chooseDir() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: ref.read(sProvider)('settings.choose_dir'),
      initialDirectory: _saveDir.isEmpty ? null : _saveDir,
    );
    if (mounted && dir != null) setState(() => _saveDirOverride = dir);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || data?.text == null) return;
    _input.text = data!.text!;
    _start();
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (!mounted || code == null) return;
    _input.text = code;
    _start();
  }

  void _onChanged(String value) {
    if (extractTakeCode(value) != null) _start();
  }

  void _start() {
    final s = ref.read(sProvider);
    final code = extractTakeCode(_input.text);
    if (code == null) {
      setState(() => _error = s('recv.invalid'));
      return;
    }
    if (_saveDir.isEmpty) {
      setState(() => _error = s('recv.no_save_dir'));
      return;
    }
    if (!ref.read(coreStateProvider).serviceAvailable) {
      setState(() => _error = s('service.unavailable'));
      return;
    }
    setState(() => _error = null);
    try {
      ref
          .read(coreStateProvider.notifier)
          .startReceive(code, saveDir: _saveDir);
      _input.clear();
      if (MobilePlatform.isMobile) _focus.unfocus();
    } on CoreException catch (e) {
      setState(() => _error = '${s('recv.invalid')} (${e.status})');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final receives = ref.watch(
      coreStateProvider.select((st) => st.receiveList),
    );
    final String saveDir =
        _saveDirOverride ??
        ref.watch(coreStateProvider.select<String>((st) => st.config.saveDir));

    // A link opened from the OS lands here.
    ref.listen<String?>(pendingReceiveProvider, (_, next) {
      if (next == null) return;
      _input.text = formatTakeCode(next);
      if (!MobilePlatform.isMobile) _focus.requestFocus();
      Future.microtask(() {
        if (!mounted) return;
        ref.read(pendingReceiveProvider.notifier).set(null);
        _start();
      });
    });

    final mobile = MediaQuery.sizeOf(context).width < 600;
    final desktop = isDesktopTheme(context);
    final compact = isCompactDesktop(context);
    final errorBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(desktop ? 8 : 12),
      borderSide: BorderSide(color: cs.error, width: 1.6),
    );
    final errorLineHeight =
        MediaQuery.textScalerOf(context).scale(12) * 1.3 + 4;
    return ListView(
      padding: compact
          ? const EdgeInsets.fromLTRB(10, 4, 10, 12)
          : EdgeInsets.fromLTRB(
              mobile ? 16 : 24,
              desktop ? 20 : (mobile ? 26 : 24),
              mobile ? 16 : 24,
              mobile ? 32 : 24,
            ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PageHeader(
                  title: s('recv.title'),
                  subtitle: s('recv.subtitle'),
                ),
                Card(
                  child: Padding(
                    padding: EdgeInsets.all(compact ? 12 : (mobile ? 16 : 20)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (desktop) ...[
                          Text(
                            s('send.code_label'),
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 10),
                        ],
                        if (MobilePlatform.isMobile) ...[
                          FilledButton.tonalIcon(
                            onPressed: _scan,
                            icon: const Icon(Icons.qr_code_scanner_rounded),
                            label: Text(s('recv.scan')),
                          ),
                          const SizedBox(height: 12),
                        ],
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _input,
                                focusNode: _focus,
                                autofocus: !MobilePlatform.isMobile,
                                textCapitalization:
                                    TextCapitalization.characters,
                                autocorrect: false,
                                onChanged: _onChanged,
                                onSubmitted: (_) => _start(),
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: desktop ? FontWeight.w400 : null,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                  letterSpacing: 0.4,
                                ),
                                decoration: InputDecoration(
                                  hintText: s(
                                    desktop
                                        ? 'recv.desktop_input_hint'
                                        : 'recv.input_hint',
                                  ),
                                  prefixIcon: desktop
                                      ? null
                                      : const Icon(Icons.qr_code_2_rounded),
                                  suffixIcon: IconButton(
                                    tooltip: s('recv.paste'),
                                    onPressed: _paste,
                                    icon: const Icon(
                                      Icons.content_paste_rounded,
                                    ),
                                  ),
                                  enabledBorder: _error == null
                                      ? null
                                      : errorBorder,
                                  focusedBorder: _error == null
                                      ? null
                                      : errorBorder,
                                ),
                              ),
                            ),
                            if (!mobile) ...[
                              const SizedBox(width: 12),
                              SizedBox(
                                height: desktop ? 44 : 54,
                                child: FilledButton.icon(
                                  onPressed: _start,
                                  icon: Icon(
                                    Icons.arrow_downward_rounded,
                                    size: desktop ? 17 : 24,
                                  ),
                                  label: Text(s('recv.start')),
                                ),
                              ),
                            ],
                          ],
                        ),
                        SizedBox(
                          height: errorLineHeight,
                          child: Padding(
                            padding: EdgeInsets.only(
                              left: desktop ? 12 : 40,
                              top: 3,
                            ),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                _error ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: cs.error,
                                  fontSize: 12,
                                  height: 1.2,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (mobile)
                          Padding(
                            padding: EdgeInsets.only(top: compact ? 0 : 12),
                            child: FilledButton.icon(
                              onPressed: _start,
                              icon: const Icon(Icons.download_rounded),
                              label: Text(s('recv.start')),
                            ),
                          ),
                        SizedBox(height: compact ? 10 : 14),
                        Container(
                          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainer,
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: compact
                              ? Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.folder_outlined,
                                          size: 17,
                                          color: cs.primary,
                                        ),
                                        const SizedBox(width: 7),
                                        Expanded(
                                          child: Text(
                                            s('recv.save_to'),
                                            style: theme.textTheme.bodySmall,
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: _chooseDir,
                                          child: Text(s('recv.change')),
                                        ),
                                      ],
                                    ),
                                    Tooltip(
                                      message: MobilePlatform.displayPath(
                                        saveDir,
                                      ),
                                      child: Text(
                                        MobilePlatform.displayPath(saveDir),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: cs.onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                  ],
                                )
                              : Row(
                                  children: [
                                    Icon(
                                      Icons.folder_outlined,
                                      size: 19,
                                      color: cs.primary,
                                    ),
                                    const SizedBox(width: 9),
                                    Text(
                                      '${s('recv.save_to')}: ',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant,
                                          ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        MobilePlatform.displayPath(saveDir),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (!MobilePlatform.isMobile)
                                      TextButton(
                                        onPressed: _chooseDir,
                                        child: Text(s('recv.change')),
                                      ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (receives.isEmpty)
                  EmptyState(
                    icon: Icons.download_done_rounded,
                    text: s('recv.empty'),
                  )
                else ...[
                  const SizedBox(height: 26),
                  Text(s('recv.history'), style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  for (final r in receives)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _ReceiveCard(r, key: ValueKey(r.transferId)),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ReceiveCard extends ConsumerWidget {
  const _ReceiveCard(this.r, {super.key});
  final ReceiveInfo r;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final t = ref.watch(
      coreStateProvider.select((st) => st.transferForReceive(r.transferId)),
    );
    final n = ref.read(coreStateProvider.notifier);
    final name = r.metaName.isNotEmpty ? r.metaName : r.code;
    final detail =
        (r.state == 'failed' || r.state == 'interrupted') &&
            r.errorCode.isNotEmpty
        ? s.errorCode(r.errorCode)
        : null;
    final paused = r.state == 'paused';
    final running =
        r.state == 'transferring' || r.state == 'verifying' || paused;
    // A rejected code never becomes valid again; only offer retry when the
    // core kept a resume token or the failure was transient.
    const permanent = {
      'code_not_found',
      'code_expired',
      'share_closed',
      'user',
    };
    final canRetry =
        (r.isInterrupted || r.state == 'failed') &&
        (r.resumable || !permanent.contains(r.errorCode));

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
                    r.metaRoots > 1 || (r.metaFiles > 1)
                        ? Icons.folder_zip_outlined
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
                        name,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(child: StateChip(r.state, detail: detail)),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              [
                r.code,
                if (r.metaFiles > 0)
                  s('send.files_bytes')
                      .replaceFirst('{files}', '${r.metaFiles}')
                      .replaceFirst('{bytes}', formatBytes(r.metaBytes)),
                MobilePlatform.displayPath(r.saveDir),
              ].join('  ·  '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 2,
                runSpacing: 2,
                children: [
                  if (running)
                    IconButton(
                      tooltip: paused ? s('recv.resume') : s('recv.pause'),
                      onPressed: () => paused
                          ? n.resumeTransfer(r.transferId)
                          : n.pauseTransfer(r.transferId),
                      icon: Icon(
                        paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      ),
                    ),
                  if (canRetry)
                    IconButton(
                      tooltip: s('recv.retry'),
                      onPressed: () => n.resumeReceive(r.transferId),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  if (r.state == 'completed')
                    IconButton(
                      tooltip: s(
                        MobilePlatform.isMobile
                            ? 'recv.export'
                            : 'recv.open_dir',
                      ),
                      onPressed: () => MobilePlatform.isMobile
                          ? MobilePlatform.exportDirectory(r.saveDir)
                          : OpenFilex.open(r.saveDir),
                      icon: const Icon(Icons.folder_open_rounded),
                    ),
                  if (r.isActive)
                    IconButton(
                      tooltip: s('recv.cancel'),
                      onPressed: () => n.cancelTransfer(r.transferId),
                      icon: const Icon(Icons.close_rounded),
                    )
                  else
                    IconButton(
                      tooltip: s('recv.remove'),
                      onPressed: () => n.removeReceive(r.transferId),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                ],
              ),
            ),
            if (t != null &&
                (running ||
                    t.state == 'completed' && r.state == 'completed')) ...[
              const SizedBox(height: 12),
              TransferProgressView(t),
            ] else if (r.isActive && !running) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(minHeight: 4),
            ],
          ],
        ),
      ),
    );
  }
}
