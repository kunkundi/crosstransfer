import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/mobile.dart';
import '../state/format.dart';
import '../state/providers.dart';

class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});
  @override
  ConsumerState<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends ConsumerState<ScanPage> {
  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_scan());
    });
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _error = null;
    });
    final s = ref.read(sProvider);
    try {
      final raw = await MobilePlatform.scanCode(
        title: s('recv.scan'),
        cancel: s('common.cancel'),
      );
      if (!mounted) return;
      if (raw == null) {
        Navigator.of(context).pop();
        return;
      }
      final code = extractTakeCode(raw);
      if (code != null) {
        Navigator.of(context).pop(code);
        return;
      }
      setState(() => _error = 'recv.invalid');
    } catch (_) {
      if (mounted) setState(() => _error = 'recv.camera_error');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  void dispose() {
    if (_scanning) {
      unawaited(MobilePlatform.cancelScan().catchError((Object _) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s('recv.scan'))),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_scanning) const CircularProgressIndicator(),
              if (_error != null) ...[
                Text(s(_error!), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _scan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(s('recv.scan')),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
