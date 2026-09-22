import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/strings.dart';
import '../platform/legal.dart';
import 'widgets.dart';

class LegalPage extends StatefulWidget {
  const LegalPage({super.key, required this.strings, required this.version});
  final S strings;
  final String version;

  @override
  State<LegalPage> createState() => _LegalPageState();
}

class _LegalPageState extends State<LegalPage> {
  bool _exporting = false;

  Future<void> _openSource(String url) async {
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // Keep the exact source URL accessible if no browser can be opened.
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.strings('legal.open_failed')),
        content: SingleChildScrollView(child: SelectableText(url)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(widget.strings('about.close')),
          ),
        ],
      ),
    );
  }

  Future<void> _exportSource(String fileName) async {
    setState(() => _exporting = true);
    try {
      final data = await rootBundle.load('assets/legal/$fileName');
      final saved = await FilePicker.saveFile(
        fileName: fileName,
        bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        mimeType: 'application/gzip',
        dialogTitle: widget.strings('legal.export_source'),
      );
      if (saved != null && mounted) {
        showSnack(context, widget.strings('legal.saved'));
      }
    } catch (_) {
      if (mounted) showSnack(context, widget.strings('legal.export_failed'));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s('legal.title'))),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'CrossTransfer ${widget.version}'.trim(),
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      s('legal.intro'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Card.outlined(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        leading: Icon(
                          Icons.description_outlined,
                          color: theme.colorScheme.primary,
                        ),
                        title: Text(s('legal.view')),
                        subtitle: Text(s('legal.license_hint')),
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          size: 20,
                        ),
                        onTap: () {
                          registerNativeLicenses();
                          showLicensePage(
                            context: context,
                            applicationName: 'CrossTransfer',
                            applicationVersion: widget.version,
                            applicationLegalese: s('legal.copyright'),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Card.outlined(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          20,
                          0,
                          20,
                          20,
                        ),
                        shape: const Border(),
                        collapsedShape: const Border(),
                        leading: Icon(
                          Icons.code_rounded,
                          color: theme.colorScheme.primary,
                        ),
                        title: Text(s('legal.source_title')),
                        subtitle: Text(s('legal.source_hint')),
                        children: [
                          Text(
                            s('legal.source_notice'),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.6,
                            ),
                          ),
                          for (final source in componentSources)
                            Padding(
                              padding: const EdgeInsets.only(top: 20),
                              child: SizedBox(
                                width: double.infinity,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Divider(height: 1),
                                    const SizedBox(height: 16),
                                    Text(
                                      source.title,
                                      style: theme.textTheme.titleSmall,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      source.license,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                    const SizedBox(height: 8),
                                    if (source.sourceUrl != null)
                                      TextButton.icon(
                                        key: ValueKey(source.fileName),
                                        onPressed: () =>
                                            _openSource(source.sourceUrl!),
                                        icon: const Icon(
                                          Icons.open_in_new_rounded,
                                          size: 18,
                                        ),
                                        label: Text(s('legal.download_source')),
                                      )
                                    else
                                      OutlinedButton.icon(
                                        key: ValueKey(source.fileName),
                                        onPressed: _exporting
                                            ? null
                                            : () => _exportSource(
                                                source.fileName,
                                              ),
                                        icon: const Icon(
                                          Icons.save_alt_rounded,
                                          size: 18,
                                        ),
                                        label: Text(s('legal.export_source')),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      s('legal.copyright'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.6,
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
