// Locates and opens the crosstransfer_native shared library.
//
// Search order: CT_NATIVE_LIB environment variable, then the platform bundle
// location produced by tools/build_native.sh, then a bare name for dlopen.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

class NativeLibrary {
  NativeLibrary._();

  static const String baseName = 'crosstransfer_native';

  static String get fileName {
    if (Platform.isWindows) return '$baseName.dll';
    if (Platform.isMacOS || Platform.isIOS) return 'lib$baseName.dylib';
    return 'lib$baseName.so';
  }

  /// Candidate absolute paths, most specific first.
  static List<String> candidates() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final out = <String>[];
    final env = Platform.environment['CT_NATIVE_LIB'];
    if (env != null && env.isNotEmpty) out.add(env);
    if (Platform.isMacOS) {
      // <App>.app/Contents/MacOS/<exe> -> <App>.app/Contents/Frameworks/
      out.add(p.normalize(p.join(exeDir, '..', 'Frameworks', fileName)));
    } else if (Platform.isWindows) {
      out.add(p.join(exeDir, fileName));
    } else if (Platform.isLinux) {
      out.add(p.join(exeDir, 'lib', fileName));
      out.add(p.join(exeDir, fileName));
    }
    return out;
  }

  static DynamicLibrary open() {
    if (Platform.isIOS) return DynamicLibrary.process();
    final tried = <String>[];
    for (final path in candidates()) {
      tried.add(path);
      if (File(path).existsSync()) return DynamicLibrary.open(path);
    }
    try {
      return DynamicLibrary.open(fileName);
    } on ArgumentError {
      throw StateError('cannot load $fileName; tried: ${tried.join(', ')}');
    }
  }
}
