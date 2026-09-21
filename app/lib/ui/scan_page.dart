import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../state/format.dart';
import '../state/providers.dart';

class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});
  @override
  ConsumerState<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends ConsumerState<ScanPage>
    with WidgetsBindingObserver {
  final _controller = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_controller.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controller.value.hasCameraPermission) return;
    if (state == AppLifecycleState.resumed && !_done) {
      unawaited(_controller.start());
    } else if (state != AppLifecycleState.resumed) {
      unawaited(_controller.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s('recv.scan'))),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          if (_done) return;
          for (final barcode in capture.barcodes) {
            final code = extractTakeCode(barcode.rawValue ?? '');
            if (code == null) continue;
            _done = true;
            Navigator.of(context).pop(code);
            break;
          }
        },
        errorBuilder: (context, error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(s('recv.camera_error'), textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
