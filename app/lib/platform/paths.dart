// Platform directories for the core and the default receive folder.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppPaths {
  const AppPaths({required this.dataDir, required this.defaultSaveDir});

  final String dataDir;
  final String defaultSaveDir;

  static String get platformName {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    return 'unknown';
  }

  static Future<AppPaths> resolve() async {
    final env = Platform.environment['CT_DATA_DIR'];
    String dataDir;
    if (env != null && env.isNotEmpty) {
      dataDir = env;
    } else {
      final support = await getApplicationSupportDirectory();
      dataDir = support.path;
    }
    await Directory(dataDir).create(recursive: true);

    if (Platform.isIOS) {
      final documents = await getApplicationDocumentsDirectory();
      final saveDir = p.join(documents.path, 'Received');
      await Directory(saveDir).create(recursive: true);
      return AppPaths(dataDir: dataDir, defaultSaveDir: saveDir);
    }

    String saveDir;
    try {
      final downloads = await getDownloadsDirectory();
      saveDir = p.join(downloads?.path ?? dataDir, 'CrossTransfer');
    } catch (_) {
      saveDir = p.join(dataDir, 'received');
    }
    return AppPaths(dataDir: dataDir, defaultSaveDir: saveDir);
  }
}
