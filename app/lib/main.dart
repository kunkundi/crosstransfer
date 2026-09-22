// CrossTransfer application entry point.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'ffi/core_client.dart';
import 'platform/desktop_basket.dart';
import 'platform/notifications.dart';
import 'platform/legal.dart';
import 'platform/paths.dart';
import 'state/app_prefs.dart';
import 'state/providers.dart';
import 'ui/shell.dart';

const String kAppVersion = '0.1.0';

bool get _isDesktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerNativeLicenses();
  if (_isDesktop) await windowManager.ensureInitialized();

  final paths = await AppPaths.resolve();
  final prefs = AppPrefs(paths.dataDir);
  await prefs.load();
  if (_isDesktop) DesktopBasket.instance.configure(prefs);

  // The core fills empty keys with its own defaults on creation and persists
  // them, so first-run defaults must be supplied up front.
  final firstRun = !File('${paths.dataDir}/config.json').existsSync();
  final createConfig = <String, dynamic>{
    'data_dir': paths.dataDir,
    'app_version': kAppVersion,
    'platform': AppPaths.platformName,
  };
  if (firstRun) {
    createConfig['log_level'] = kDebugMode ? 'debug' : 'info';
    createConfig['save_dir'] = paths.defaultSaveDir;
  }
  final client = CoreClient.create(createConfig);

  runApp(ProviderScope(
    overrides: [
      appPrefsProvider.overrideWithValue(prefs),
      coreClientProvider.overrideWithValue(client),
    ],
    child: const CrossTransferApp(),
  ));
  // A notification permission dialog must not block startup or link delivery.
  unawaited(DesktopNotifier.instance.init());

  if (_isDesktop) {
    const options = WindowOptions(
      size: Size(980, 680),
      minimumSize: Size(720, 520),
      center: true,
      title: 'CrossTransfer',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
}
