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
import 'about_page.dart';

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
      initialDirectory: _saveDir.isEmpty ? null : _saveDir,
    );
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
    final mobile = MediaQuery.sizeOf(context).width < 600;

    return ListView(
      padding: EdgeInsets.fromLTRB(
        mobile ? 16 : 24,
        mobile ? 26 : 20,
        mobile ? 16 : 24,
        mobile ? 32 : 24,
      ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PageHeader(
                  title: s('settings.title'),
                  subtitle: s('settings.subtitle'),
                ),
                _SettingsGroup(
                  icon: Icons.tune_rounded,
                  title: s('settings.general'),
                  children: [
                    _Row(
                      label: s('settings.save_dir'),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              MobilePlatform.displayPath(_saveDir),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (!MobilePlatform.isMobile) ...[
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: _chooseDir,
                              icon: const Icon(
                                Icons.folder_open_outlined,
                                size: 18,
                              ),
                              label: Text(s('recv.change')),
                            ),
                          ],
                        ],
                      ),
                    ),
                    _Row(
                      label: s('settings.language'),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SegmentedButton<String>(
                          segments: [
                            for (final l in S.supported)
                              ButtonSegment(
                                value: l,
                                label: Text(S.languageName(l)),
                              ),
                          ],
                          selected: {lang},
                          onSelectionChanged: (v) =>
                              ref.read(languageProvider.notifier).set(v.first),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _SettingsGroup(
                  icon: Icons.ios_share_rounded,
                  title: s('settings.share'),
                  children: [
                    _Row(
                      label: s('settings.share_mode'),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SegmentedButton<String>(
                          segments: [
                            ButtonSegment(
                              value: 'once',
                              label: Text(s('send.mode.once')),
                            ),
                            ButtonSegment(
                              value: 'open',
                              label: Text(s('send.mode.open')),
                            ),
                          ],
                          selected: {_shareMode},
                          onSelectionChanged: (v) => setState(() {
                            _shareMode = v.first;
                            _dirty = true;
                          }),
                        ),
                      ),
                    ),
                    _Row(
                      label: s('settings.share_ttl'),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: 160,
                          child: TextField(
                            controller: _ttl,
                            onChanged: (_) => _mark(),
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(isDense: true),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (MobilePlatform.isMobile) ...[
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                      child: const ImportStorage(),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (_dirty)
                      TextButton(
                        onPressed: () => setState(() => _loadFrom(config)),
                        child: Text(s('common.cancel')),
                      ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _dirty ? _save : null,
                      icon: const Icon(Icons.check_rounded),
                      label: Text(s('settings.save')),
                    ),
                  ],
                ),
                const SizedBox(height: 26),
                Text(
                  s('settings.about'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 8,
                    ),
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.info_outline_rounded,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                    title: Text(s('settings.about')),
                    subtitle: Text('CrossTransfer ${config.appVersion}'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AboutPage(
                          strings: s,
                          version: config.appVersion,
                          coreVersion: CoreClient.version,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, size: 19, color: colors.onPrimaryContainer),
                ),
                const SizedBox(width: 11),
                Text(title, style: theme.textTheme.titleMedium),
              ],
            ),
          ),
          for (var i = 0; i < children.length; i++) ...[
            const Divider(indent: 18, endIndent: 18),
            children[i],
          ],
        ],
      ),
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
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label, style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            child,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 148,
            child: Text(label, style: theme.textTheme.labelLarge),
          ),
          const SizedBox(width: 12),
          Expanded(child: child),
        ],
      ),
    );
  }
}
