// Exercises the actual packaged ABI without a server or Flutter engine.
// CT_NATIVE_LIB=<absolute library path> dart run tool/native_check.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crosstransfer/ffi/core_client.dart';
import 'package:crosstransfer/ffi/native_library.dart';

Future<void> main() async {
  final library = NativeLibrary.open();
  final header = File('../core/include/crosstransfer/ct_api.h').readAsStringSync();
  final names = RegExp(r'CT_API\s+[^;]+?\b(Ct\w+)\s*\(')
      .allMatches(header).map((m) => m.group(1)!).toSet();
  for (final name in names) {
    if (!library.providesSymbol(name)) throw StateError('missing export: $name');
  }
  final dir = Directory.systemTemp.createTempSync('ct-native-check-');
  CoreClient? client;
  try {
    client = CoreClient.create({'data_dir': dir.path, 'log_level': 'error'});
    final event = client.events.firstWhere((e) => e['type'] == 'config')
        .timeout(const Duration(seconds: 10));
    client.updateConfig({'link_host': 'ffi-check.example'});
    await event;
    final config = client.query('config');
    if (!jsonEncode(config).contains('ffi-check.example')) {
      throw StateError('config update/query round trip failed: $config');
    }
    stdout.writeln('PASS: ${names.length} exports, core ${CoreClient.version}, '
        'owned callback, config round trip');
  } finally {
    client?.dispose();
    // Drain already posted NativeCallable events before exiting the isolate.
    await Future<void>.delayed(Duration.zero);
    dir.deleteSync(recursive: true);
  }
}
