// System tray icon and close-to-tray behaviour for desktop.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

// The 0.5-compatible tray API is the documented bridge for tray_manager 0.7.
// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/window_manager.dart';

import '../i18n/strings.dart';
import 'desktop_window.dart';

class DesktopTray with TrayListener, WindowListener {
  DesktopTray._();
  static final DesktopTray instance = DesktopTray._();

  bool _installed = false;
  bool _quitting = false;

  static bool get supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  Future<void> install(S s) async {
    if (!supported) return;
    const icon = "assets/tray_icon.png";
    try {
      await trayManager.setIcon(icon, isTemplate: Platform.isMacOS);
      await trayManager.setToolTip(s('app.title'));
      await setMenu(s);
      if (!_installed) {
        trayManager.addListener(this);
        windowManager.addListener(this);
        await windowManager.setPreventClose(true);
        _installed = true;
      }
    } catch (e) {
      debugPrint('tray unavailable: $e');
      // Without a working tray, closing must not leave an inaccessible app.
      await windowManager.setPreventClose(false);
    }
  }

  Future<void> setMenu(S s) async {
    if (!supported) return;
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: s('tray.show')),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: s('tray.quit')),
        ],
      ),
    );
  }

  Future<void> showWindow() async {
    if (!supported) return;
    await DesktopWindow.instance.show();
  }

  Future<void> quit() async {
    _quitting = true;
    await windowManager.setPreventClose(false);
    await trayManager.destroy();
    await windowManager.close();
    exit(0);
  }

  @override
  void onTrayIconMouseDown() {
    if (Platform.isLinux) return;
    // Let the macOS status-item click finish before changing the app's window
    // activation state. Showing a key window from inside the native click
    // callback can leave it ordered behind other apps until another status-bar
    // interaction occurs.
    Timer.run(() => unawaited(showWindow()));
  }

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showWindow();
      case 'quit':
        quit();
    }
  }

  @override
  void onWindowClose() async {
    if (_quitting) return;
    if (await windowManager.isPreventClose()) {
      await DesktopWindow.instance.hide();
    }
  }

  @override
  void onWindowMove() => DesktopWindow.instance.schedulePositionSave();

  @override
  void onWindowMoved() => DesktopWindow.instance.schedulePositionSave();
}
