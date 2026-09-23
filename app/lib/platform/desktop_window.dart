// The single compact desktop window, including persistent position and pinning.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Alignment;
import 'package:window_manager/window_manager.dart';

import '../state/app_prefs.dart';

class DesktopWindow extends ChangeNotifier {
  DesktopWindow._();
  static final DesktopWindow instance = DesktopWindow._();
  static const size = Size(360, 420);

  AppPrefs? _prefs;
  bool _pinned = true;
  bool _initialized = false;
  Timer? _positionSaveTimer;

  static bool get supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  bool get pinned => _pinned;

  void configure(AppPrefs prefs) {
    _prefs = prefs;
    final savedPinned =
        prefs.values['window_pinned'] ?? prefs.values['basket_pinned'];
    if (savedPinned is bool) _pinned = savedPinned;
  }

  Future<void> initialize() async {
    if (!supported || _initialized) return;
    const options = WindowOptions(
      size: size,
      minimumSize: size,
      maximumSize: size,
      center: true,
      fullScreen: false,
      title: 'CrossTransfer',
      // Let the OS own dragging, window buttons, inactive appearance and
      // accessibility instead of painting a shared Flutter title bar.
      titleBarStyle: TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
    await windowManager.waitUntilReadyToShow(options);
    await windowManager.setResizable(false);
    await windowManager.setMaximizable(false);
    await windowManager.setAlwaysOnTop(_pinned);
    // Retain the taskbar/Dock entry: the only window must be easy to recover,
    // including when the desktop environment does not provide a tray.
    await windowManager.setSkipTaskbar(false);
    await _restorePosition();
    _initialized = true;
    await show();
  }

  Future<void> show() async {
    if (!supported) return;
    await windowManager.show();
    if (Platform.isMacOS) await Future<void>.delayed(Duration.zero);
    await windowManager.focus();
  }

  Future<void> hide() async {
    if (!supported) return;
    await _savePosition();
    await windowManager.hide();
  }

  Future<void> togglePinned() async {
    if (!supported) return;
    _pinned = !_pinned;
    notifyListeners();
    await _prefs?.set('window_pinned', _pinned);
    if (_initialized) await windowManager.setAlwaysOnTop(_pinned);
  }

  void schedulePositionSave() {
    if (!_initialized) return;
    _positionSaveTimer?.cancel();
    _positionSaveTimer = Timer(
      const Duration(milliseconds: 350),
      _savePosition,
    );
  }

  Future<void> _restorePosition() async {
    final saved =
        _prefs?.values['window_position'] ?? _prefs?.values['basket_position'];
    if (saved is! Map || saved['x'] is! num || saved['y'] is! num) return;
    final topLeft = await calcWindowPosition(size, Alignment.topLeft);
    final bottomRight = await calcWindowPosition(size, Alignment.bottomRight);
    await windowManager.setPosition(
      Offset(
        (saved['x'] as num)
            .toDouble()
            .clamp(topLeft.dx, bottomRight.dx)
            .toDouble(),
        (saved['y'] as num)
            .toDouble()
            .clamp(topLeft.dy, bottomRight.dy)
            .toDouble(),
      ),
    );
  }

  Future<void> _savePosition() async {
    if (!_initialized || _prefs == null) return;
    try {
      final position = await windowManager.getPosition();
      await _prefs!.set('window_position', {
        'x': position.dx,
        'y': position.dy,
      });
    } catch (error) {
      debugPrint('failed to save window position: $error');
    }
  }
}
