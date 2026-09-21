// Settings page: save folder, server, network, share defaults, language.
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

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _linkHost = TextEditingController();
  final _ttl = TextEditingController();
  bool _tls = true;
  bool _upnp = false;
  String _turn = 'auto';
  String _relay = 'auto';
  String _shareMode = 'once';
  String _logLevel = 'info';
  String _saveDir = '';
  bool _dirty = false;
  bool _loaded = false;

  void _loadFrom(CoreConfig c) {
    _host.text = c.serverHost;
    _port.text = '${c.serverPort}';
    _linkHost.text = c.linkHost;
    _ttl.text = '${c.shareTtlSec}';
    _tls = c.serverTls;
    _upnp = c.enableUpnp;
    _turn = c.turnMode;
    _relay = c.wsRelay;
    _shareMode = c.shareMode;
    _logLevel = c.logLevel;
    _saveDir = c.saveDir;
    _dirty = false;
    _loaded = true;
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _linkHost.dispose();
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
    final port = int.tryParse(_port.text.trim());
    if (port == null || port <= 0 || port > 65535) {
      showSnack(context, s('settings.invalid_port'));
      return;
    }
    final ttl = int.tryParse(_ttl.text.trim());
    if (ttl == null || ttl < 30 || ttl > 86400) {
      showSnack(context, s('settings.invalid_ttl'));
      return;
    }
    final patch = <String, dynamic>{
      'server': {
        'host': _host.text.trim(),
        'port': port,
        'tls': _tls,
      },
      'link_host': _linkHost.text.trim(),
      'turn_mode': _turn,
      'ws_relay': _relay,
      'enable_upnp': _upnp,
      'save_dir': _saveDir,
      'share': {'mode': _shareMode, 'ttl_sec': ttl},
      'log_level': _logLevel,
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
        SectionTitle(s('settings.server')),
        _Row(
          label: s('settings.server_host'),
          child: TextField(
            controller: _host,
            onChanged: (_) => _mark(),
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
          ),
        ),
        _Row(
          label: s('settings.server_port'),
          child: SizedBox(
            width: 120,
            child: TextField(
              controller: _port,
              onChanged: (_) => _mark(),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            ),
          ),
        ),
        _Row(
          label: s('settings.server_tls'),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Switch(
              value: _tls,
              onChanged: (v) => setState(() {
                _tls = v;
                _dirty = true;
              }),
            ),
          ),
        ),
        _Row(
          label: s('settings.link_host'),
          hint: s('settings.link_host_hint'),
          child: TextField(
            controller: _linkHost,
            onChanged: (_) => _mark(),
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
          ),
        ),
        SectionTitle(s('settings.network')),
        _Row(
          label: s('settings.turn_mode'),
          child: _ModeSelector(
            value: _turn,
            onChanged: (v) => setState(() {
              _turn = v;
              _dirty = true;
            }),
          ),
        ),
        _Row(
          label: s('settings.ws_relay'),
          child: _ModeSelector(
            value: _relay,
            onChanged: (v) => setState(() {
              _relay = v;
              _dirty = true;
            }),
          ),
        ),
        _Row(
          label: s('settings.upnp'),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Switch(
              value: _upnp,
              onChanged: (v) => setState(() {
                _upnp = v;
                _dirty = true;
              }),
            ),
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
        SectionTitle(s('settings.about')),
        _Row(
            label: s('settings.version'),
            child: Text('${config.appVersion}  (core ${CoreClient.version})')),
        _Row(label: s('settings.data_dir'), child: SelectableText(config.dataDir)),
        _Row(label: s('settings.log_dir'), child: SelectableText(config.logDir)),
        _Row(
          label: s('settings.log_level'),
          child: DropdownButton<String>(
            value: _logLevel,
            isDense: true,
            items: [
              for (final l in const ['trace', 'debug', 'info', 'warn', 'error'])
                DropdownMenuItem(value: l, child: Text(l)),
            ],
            onChanged: (v) => setState(() {
              _logLevel = v ?? 'info';
              _dirty = true;
            }),
          ),
        ),
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
  const _Row({required this.label, required this.child, this.hint});
  final String label;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (MediaQuery.sizeOf(context).width < 600) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(label, style: theme.textTheme.bodyMedium),
          if (hint != null) Text(hint!, style: theme.textTheme.bodySmall),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodyMedium),
                if (hint != null)
                  Text(hint!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _ModeSelector extends ConsumerWidget {
  const _ModeSelector({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    return SegmentedButton<String>(
      segments: [
        for (final m in ['auto', 'force', 'off'])
          ButtonSegment(value: m, label: Text(s('settings.mode.$m'))),
      ],
      selected: {value},
      onSelectionChanged: (v) => onChanged(v.first),
    );
  }
}
