import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/mobile.dart';
import '../state/format.dart';
import '../state/providers.dart';
import 'widgets.dart';

class ImportStorage extends ConsumerStatefulWidget {
  const ImportStorage({super.key});
  @override
  ConsumerState<ImportStorage> createState() => _ImportStorageState();
}

class _ImportStorageState extends ConsumerState<ImportStorage> {
  Map<String, dynamic>? _usage;
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final usage = await MobilePlatform.importStorage();
      if (mounted) setState(() => _usage = usage);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final ids = (_usage?['ids'] as List? ?? []).cast<String>().toList();
    if (_busy || ids.isEmpty || ref.read(coreStateProvider).hasSendWork) return;
    final s = ref.read(sProvider);
    // Copy the preview IDs before confirmation. New imports are never swept up.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s('storage.clear')),
        content: Text(s('storage.confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(s('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(s('storage.clear')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final usage = await ref
          .read(coreStateProvider.notifier)
          .clearImports(ids);
      if (mounted) {
        setState(() => _usage = usage);
        showSnack(context, s('storage.done'));
      }
    } catch (_) {
      if (mounted) showSnack(context, s('storage.failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sProvider);
    final sending = ref.watch(
      coreStateProvider.select((state) => state.hasSendWork),
    );
    final ids = _usage?['ids'] as List? ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(s('storage.title')),
        Text(s('storage.hint')),
        const SizedBox(height: 8),
        if (_usage != null)
          Text(
            '${s('storage.used')}: ${formatBytes((_usage!['bytes'] as num).toInt())} · ${s('storage.clearable')}: ${formatBytes((_usage!['clearable_bytes'] as num).toInt())}',
          ),
        if (_failed) Text(s('storage.failed')),
        if (sending) Text(s('storage.sending')),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: _busy || sending || ids.isEmpty ? null : _clear,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: Text(s('storage.clear')),
            ),
            IconButton(
              onPressed: _busy ? null : _refresh,
              tooltip: s('storage.refresh'),
              icon: const Icon(Icons.refresh),
            ),
            if (_busy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ],
    );
  }
}
