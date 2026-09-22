// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/strings.dart';
import 'legal_page.dart';
import 'widgets.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({
    super.key,
    required this.strings,
    required this.version,
    required this.coreVersion,
  });

  final S strings;
  final String version;
  final String coreVersion;

  String get _versionLabel => version.isEmpty ? '—' : version;

  void _showVersionDetails(BuildContext context) {
    final s = strings;
    final platform = switch (Theme.of(context).platform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iOS',
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.linux => 'Linux',
      TargetPlatform.fuchsia => 'Fuchsia',
    };
    final details = <String, String>{
      s('about.app_version'): _versionLabel,
      if (coreVersion.isNotEmpty) s('about.core_version'): coreVersion,
      s('about.platform'): platform,
    };
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(s('about.version_details')),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: SelectionArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry in details.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.key,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entry.value,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(s('about.close')),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: Text(s('about.copy_version')),
            onPressed: () async {
              var message = s('about.version_copied');
              try {
                await Clipboard.setData(
                  ClipboardData(
                    text: [
                      'CrossTransfer',
                      for (final entry in details.entries)
                        '${entry.key}: ${entry.value}',
                    ].join('\n'),
                  ),
                );
              } catch (_) {
                message = s('about.copy_failed');
              }
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              if (context.mounted) showSnack(context, message);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = strings;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(s('settings.about'))),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: ExcludeSemantics(
                        child: Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            color: colors.primaryContainer,
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: Icon(
                            Icons.swap_horiz_rounded,
                            size: 44,
                            color: colors.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'CrossTransfer',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      s('about.tagline'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${s('settings.version')} $_versionLabel',
                          style: theme.textTheme.labelMedium,
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        s('about.description'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.6,
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    Card.outlined(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          _AboutItem(
                            icon: Icons.info_outline_rounded,
                            title: s('about.version_details'),
                            subtitle: s('about.version_hint'),
                            onTap: () => _showVersionDetails(context),
                          ),
                          const Divider(height: 1, indent: 20, endIndent: 20),
                          _AboutItem(
                            icon: Icons.description_outlined,
                            title: s('legal.title'),
                            subtitle: s('about.legal_hint'),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    LegalPage(strings: s, version: version),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    Text(
                      s('about.copyright'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutItem extends StatelessWidget {
  const _AboutItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: Icon(icon, color: colors.primary),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: onTap,
    );
  }
}
