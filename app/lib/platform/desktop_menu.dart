// Connect the existing AppKit menus without replacing native Edit/Window menus.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:io';

import 'package:flutter/services.dart';

import '../i18n/strings.dart';

class DesktopMenu {
  static const _channel = MethodChannel('com.crosstransfer/navigation');

  static Future<void> start(S strings, void Function(int) onSelected) async {
    if (!Platform.isMacOS) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'SelectPage' &&
          call.arguments is int &&
          (call.arguments as int) >= 0 &&
          (call.arguments as int) < 3) {
        onSelected(call.arguments as int);
      }
    });
    await update(strings);
  }

  static Future<void> update(S strings) async {
    if (!Platform.isMacOS) return;
    await _channel.invokeMethod<void>('Configure', {
      'labels': [
        strings('nav.send'),
        strings('nav.receive'),
        strings('nav.settings'),
      ],
    });
  }

  static void stop() {
    if (Platform.isMacOS) _channel.setMethodCallHandler(null);
  }
}
