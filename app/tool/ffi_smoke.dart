// FFI smoke test: drives the core through CoreClient without Flutter.
//
//   CT_NATIVE_LIB=../build/macosx/arm64/release/libcrosstransfer_native.dylib \
//   dart run tool/ffi_smoke.dart share <path> [--server host:port]
//   dart run tool/ffi_smoke.dart receive <code> <save_dir> [--server host:port]
//
// Prints core events as JSON lines; exits 0 on completion.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crosstransfer/ffi/core_client.dart';

Future<void> main(List<String> argv) async {
  final args = List<String>.from(argv);
  var server = '127.0.0.1:8080';
  final i = args.indexOf('--server');
  if (i >= 0 && i + 1 < args.length) {
    server = args[i + 1];
    args.removeRange(i, i + 2);
  }
  if (args.length < 2) {
    stderr.writeln('usage: share <path> | receive <code> <save_dir>');
    exit(2);
  }
  final cmd = args[0];
  final host = server.split(':')[0];
  final port = int.parse(server.split(':')[1]);
  final dataDir = Directory.systemTemp.createTempSync('ct_ffi_smoke_').path;

  final client = CoreClient.create({
    'data_dir': dataDir,
    'log_level': 'warn',
    'server': {'host': host, 'port': port, 'tls': false, 'path': '/ws'},
    'turn_mode': 'auto',
    'app_version': CoreClient.version,
    'platform': 'dart-smoke',
  });
  stdout.writeln('core version ${CoreClient.version}, data_dir $dataDir');

  final done = Completer<int>();
  late final StreamSubscription sub;
  sub = client.events.listen((ev) {
    stdout.writeln(jsonEncode(ev));
    final type = ev['type'];
    final state = ev['state'];
    if (type == 'signal_state' && (state == 'failed' || state == 'tls_error')) {
      done.complete(1);
    } else if (type == 'share_state' && state == 'ready') {
      stdout.writeln('CODE ${ev['code']}');
      stdout.writeln('LINK ${ev['link']}');
    } else if (type == 'share_state' && (state == 'failed' || state == 'closed')) {
      if (!done.isCompleted) done.complete(1);
    } else if (type == 'transfer_state' && state == 'completed') {
      if (!done.isCompleted) done.complete(0);
    } else if (type == 'receive_state' && (state == 'failed' || state == 'cancelled')) {
      if (!done.isCompleted) done.complete(1);
    }
  });

  try {
    if (cmd == 'share') {
      final id = client.shareCreate([File(args[1]).absolute.path]);
      stdout.writeln('share id $id');
    } else if (cmd == 'receive') {
      if (args.length < 3) {
        stderr.writeln('receive needs <code> <save_dir>');
        exit(2);
      }
      final id = client.receiveStart(args[1], saveDir: args[2]);
      stdout.writeln('transfer id $id');
    } else {
      stderr.writeln('unknown command $cmd');
      exit(2);
    }
    final snapshot = client.query('all');
    stdout.writeln('query: ${jsonEncode(snapshot)}');
    final code = await done.future.timeout(const Duration(seconds: 120), onTimeout: () => 124);
    // Let the final ctrl messages flush before tearing down.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await sub.cancel();
    client.dispose();
    exit(code);
  } on CoreException catch (e) {
    stderr.writeln('core error: $e');
    client.dispose();
    exit(1);
  }
}
