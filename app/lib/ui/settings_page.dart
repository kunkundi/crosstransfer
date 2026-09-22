// Settings page: user preferences, share defaults, language and about.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ffi/core_client.dart';
import '../platform/mobile.dart';
import '../i18n/strings.dart';
import '../state/models.dart';
import '../state/providers.dart';
import 'widgets.dart';
import 'import_storage.dart';
import 'legal_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _ttl = TextEditingController();
  String _shareMode = 'once';
  String _saveDir = '';
  bool _dirty = false;
  bool _loaded = false;

  void _loadFrom(CoreConfig c) {
    _ttl.text = '${c.shareTtlSec}';
    _shareMode = c.shareMode;
    _saveDir = c.saveDir;
    _dirty = false;
    _loaded = true;
  }

  @override
  void dispose() {
    _ttl.dispose();
    super.dispose();
  }

  void _mark() => setState(() => _dirty = true);

  Future<void> _chooseDir() async {
    final dir = await FilePicker.getDirectoryPath(
        dialogTitle: ref.read(sProvider)('settings.choose_dir'),
        initialDirectory: _saveDir.isEmpty ? null : _saveDir);
    if (dir != null) {
      setState(() {
        _saveDir = dir;
        _dirty = true;
      });
    }
  }

  void _save() {
    final s = ref.read(sProvider);
    final ttl = int.tryParse(_ttl.text.trim());
    if (ttl == null || ttl < 30 || ttl > 86400) {
      showSnack(context, s('settings.invalid_ttl'));
      return;
    }
    final patch = <String, dynamic>{
      'save_dir': _saveDir,
      'share': {'mode': _shareMode, 'ttl_sec': ttl},
    };
    try {
      ref.read(coreStateProvider.notifier).updateConfig(patch);
      setState(() => _dirty = false);
      showSnack(context, s('settings.saved'));
    } on CoreException catch (e) {
      showSnack(context, '${s('common.error')} ${e.status}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sProvider);
    final config = ref.watch(coreStateProvider.select((st) => st.config));
    final lang = ref.watch(languageProvider);
    if (!_loaded) _loadFrom(config);
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      children: [
        SectionTitle(s('settings.general')),
        _Row(
          label: s('settings.save_dir'),
          child: Row(children: [
            Expanded(
              child: Text(MobilePlatform.displayPath(_saveDir), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (!MobilePlatform.isMobile) TextButton(onPressed: _chooseDir, child: Text(s('recv.change'))),
          ]),
        ),
        _Row(
          label: s('settings.language'),
          child: SegmentedButton<String>(
            segments: [
              for (final l in S.supported)
                ButtonSegment(value: l, label: Text(S.languageName(l))),
            ],
            selected: {lang},
            onSelectionChanged: (v) =>
                ref.read(languageProvider.notifier).set(v.first),
          ),
        ),
        SectionTitle(s('settings.share')),
        _Row(
          label: s('settings.share_mode'),
          child: SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'once', label: Text(s('send.mode.once'))),
              ButtonSegment(value: 'open', label: Text(s('send.mode.open'))),
            ],
            selected: {_shareMode},
            onSelectionChanged: (v) => setState(() {
              _shareMode = v.first;
              _dirty = true;
            }),
          ),
        ),
        _Row(
          label: s('settings.share_ttl'),
          child: SizedBox(
            width: 120,
            child: TextField(
              controller: _ttl,
              onChanged: (_) => _mark(),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            ),
          ),
        ),
        if (MobilePlatform.isMobile) const ImportStorage(),
        SectionTitle(s('settings.about')),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.balance_outlined),
          title: Text(s('legal.title')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => LegalPage(strings: s, version: config.appVersion),
          )),
        ),
        _Row(
            label: s('settings.version'),
            child: Text('${config.appVersion}  (core ${CoreClient.version})')),
        const SizedBox(height: 24),
        Row(children: [
          FilledButton.icon(
            onPressed: _dirty ? _save : null,
            icon: const Icon(Icons.save_outlined),
            label: Text(s('settings.save')),
          ),
          const SizedBox(width: 12),
          if (_dirty)
            TextButton(
              onPressed: () => setState(() => _loadFrom(config)),
              child: Text(s('common.cancel')),
            ),
        ]),
        const SizedBox(height: 24),
        Text(
          'CrossTransfer ${config.appVersion} · ${theme.platform.name}',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (MediaQuery.sizeOf(context).width < 600) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(label, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          child,
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 180,
            child: Text(label, style: theme.textTheme.bodyMedium),
          ),
          const SizedBox(width: 16),
          Expanded(child: child),
        ],
      ),
    );
  }
}
