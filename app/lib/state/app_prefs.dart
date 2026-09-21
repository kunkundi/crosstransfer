// UI-only preferences (language, last receive dir) stored as JSON next to the
// core's config.json. Core-owned settings go through CtUpdateConfig instead.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class AppPrefs {
  AppPrefs(this.dataDir) : _file = File(p.join(dataDir, 'ui.json'));

  final String dataDir;
  final File _file;
  Map<String, dynamic> _values = {};

  Map<String, dynamic> get values => _values;

  Future<void> load() async {
    try {
      if (await _file.exists()) {
        final decoded = jsonDecode(await _file.readAsString());
        if (decoded is Map<String, dynamic>) _values = decoded;
      }
    } catch (_) {
      _values = {};
    }
  }

  Future<void> set(String key, Object? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode(_values));
    } catch (_) {}
  }

  String get language {
    final v = _values['language'];
    if (v is String && v.isNotEmpty) return v;
    final sys = Platform.localeName.toLowerCase();
    return sys.startsWith('zh') ? 'zh' : 'en';
  }
}
