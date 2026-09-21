import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    return Scaffold(
      appBar: AppBar(title: Text(s('legal.title'))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'CrossTransfer ${widget.version}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(s('legal.copyright')),
          const SizedBox(height: 24),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.description_outlined),
            title: Text(s('legal.view')),
            trailing: const Icon(Icons.chevron_right),
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
          const Divider(),
          const SizedBox(height: 12),
          Text(
            s('legal.source_title'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(s('legal.source_notice')),
          const SizedBox(height: 16),
          for (final source in mplSources)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(source.title),
              subtitle: const Text('MPL-2.0'),
              trailing: OutlinedButton.icon(
                key: ValueKey(source.fileName),
                onPressed: _exporting
                    ? null
                    : () => _exportSource(source.fileName),
                icon: const Icon(Icons.save_alt),
                label: Text(s('legal.export_source')),
              ),
            ),
        ],
      ),
    );
  }
}
