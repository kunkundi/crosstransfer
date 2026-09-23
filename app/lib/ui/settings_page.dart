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
import 'theme.dart';

TextStyle _desktopOptionStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodyMedium!
        .copyWith(fontSize: 12, fontWeight: FontWeight.w400, height: 1.4);

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
    if (isDesktopTheme(context)) return _desktopSettings(s, config, lang);
    final mobile = MediaQuery.sizeOf(context).width < 600;

    return ListView(
      padding: isCompactDesktop(context)
          ? const EdgeInsets.fromLTRB(10, 4, 10, 12)
          : EdgeInsets.fromLTRB(
              mobile ? 16 : 24,
              isDesktopTheme(context) ? 20 : (mobile ? 26 : 24),
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
                      child: _ChoiceSurface(
                        child: SegmentedButton<String>(
                          showSelectedIcon: !isDesktopTheme(context),
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
                      child: _ChoiceSurface(
                        child: SegmentedButton<String>(
                          showSelectedIcon: !isDesktopTheme(context),
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
                        alignment: isDesktopTheme(context)
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: SizedBox(
                          width: isDesktopTheme(context) ? 108 : 160,
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

  Widget _desktopSettings(S s, CoreConfig config, String lang) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final optionStyle = _desktopOptionStyle(context);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
            children: [
              _SettingsGroup(
                icon: Icons.tune_rounded,
                title: s('settings.general'),
                children: [
                  Tooltip(
                    message: _saveDir,
                    child: InkWell(
                      key: const Key('settings-save-location'),
                      onTap: _chooseDir,
                      child: _PreferenceRow(
                        label: s('settings.save_location'),
                        value: _saveDir.isEmpty ? '—' : _saveDir,
                        wrapValue: true,
                        icon: Icons.chevron_right_rounded,
                      ),
                    ),
                  ),
                  _PreferenceChoice(
                    key: const Key('settings-language'),
                    label: s('settings.language'),
                    value: lang,
                    choices: {
                      for (final language in S.supported)
                        language: S.languageName(language),
                    },
                    onChanged: (value) =>
                        ref.read(languageProvider.notifier).set(value),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _SettingsGroup(
                icon: Icons.ios_share_rounded,
                title: s('settings.share'),
                children: [
                  _PreferenceChoice(
                    key: const Key('settings-share-mode'),
                    label: s('settings.default_mode'),
                    value: _shareMode,
                    choices: {
                      'once': s('send.mode.once'),
                      'open': s('send.mode.open'),
                    },
                    onChanged: (value) => setState(() {
                      _shareMode = value;
                      _dirty = true;
                    }),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            s('settings.code_lifetime'),
                            style: optionStyle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 94,
                          child: TextField(
                            key: const Key('settings-ttl'),
                            controller: _ttl,
                            onChanged: (_) => _mark(),
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.right,
                            style: optionStyle,
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 7,
                              ),
                              suffixText: s('settings.seconds'),
                              suffixStyle: optionStyle.copyWith(
                                fontSize: 11,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AboutPage(
                        strings: s,
                        version: config.appVersion,
                        coreVersion: CoreClient.version,
                      ),
                    ),
                  ),
                  child: _PreferenceRow(
                    label: s('settings.about'),
                    value: config.appVersion,
                    icon: Icons.chevron_right_rounded,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_dirty)
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      style: TextButton.styleFrom(textStyle: optionStyle),
                      onPressed: () => setState(() => _loadFrom(config)),
                      child: Text(s('common.cancel')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        textStyle: optionStyle.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      onPressed: _save,
                      child: Text(s('settings.save')),
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

class _PreferenceRow extends StatelessWidget {
  const _PreferenceRow({
    required this.label,
    required this.value,
    required this.icon,
    this.wrapValue = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool wrapValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final optionStyle = _desktopOptionStyle(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 34),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            Expanded(flex: 5, child: Text(label, style: optionStyle)),
            const SizedBox(width: 8),
            Expanded(
              flex: 6,
              child: Text(
                value,
                maxLines: wrapValue ? null : 1,
                overflow: wrapValue
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: optionStyle.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 4),
            Icon(icon, size: 15, color: colors.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _PreferenceChoice extends StatefulWidget {
  const _PreferenceChoice({
    super.key,
    required this.label,
    required this.value,
    required this.choices,
    required this.onChanged,
  });

  final String label;
  final String value;
  final Map<String, String> choices;
  final ValueChanged<String> onChanged;

  @override
  State<_PreferenceChoice> createState() => _PreferenceChoiceState();
}

class _PreferenceChoiceState extends State<_PreferenceChoice> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    final value = widget.value;
    final choices = widget.choices;
    return MenuAnchor(
      childFocusNode: _focus,
      style: const MenuStyle(alignment: Alignment.bottomRight),
      menuChildren: [
        for (final entry in choices.entries)
          MenuItemButton(
            onPressed: () {
              if (entry.key != value) widget.onChanged(entry.key);
            },
            leadingIcon: Icon(
              entry.key == value ? Icons.check : null,
              size: 14,
            ),
            child: Semantics(
              selected: entry.key == value,
              child: Text(entry.value),
            ),
          ),
      ],
      builder: (context, controller, _) => Semantics(
        button: true,
        expanded: controller.isOpen,
        child: InkWell(
          focusNode: _focus,
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: _PreferenceRow(
            label: label,
            value: choices[value] ?? value,
            icon: Icons.unfold_more_rounded,
          ),
        ),
      ),
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
    if (isDesktopTheme(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 5),
            child: Text(
              title,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1.3,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const Divider(indent: 16, endIndent: 16),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      );
    }
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
    if (MediaQuery.sizeOf(context).width <
            (isDesktopTheme(context) ? 400 : 600) ||
        MediaQuery.textScalerOf(context).scale(13) > 16) {
      return Padding(
        padding: isCompactDesktop(context)
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
            : const EdgeInsets.fromLTRB(18, 14, 18, 16),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: isDesktopTheme(context) ? 126 : 148,
            child: Text(
              label,
              style: isDesktopTheme(context)
                  ? theme.textTheme.bodyMedium
                  : theme.textTheme.labelLarge,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _ChoiceSurface extends StatelessWidget {
  const _ChoiceSurface({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktopTheme(context);
    return Align(
      alignment: desktop ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: desktop ? const EdgeInsets.all(3) : EdgeInsets.zero,
        decoration: desktop
            ? BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: child,
      ),
    );
  }
}
