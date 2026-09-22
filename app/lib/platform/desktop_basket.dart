// Compact desktop window mode used as a cross-platform quick-drop basket.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Alignment;
import 'package:window_manager/window_manager.dart';

import '../state/app_prefs.dart';

class DesktopBasket extends ChangeNotifier {
  DesktopBasket._();
  static final DesktopBasket instance = DesktopBasket._();

  static const size = Size(420, 300);
  static const _mainMinimumSize = Size(720, 520);
  static const _unboundedMaximumSize = Size(100000, 100000);

  AppPrefs? _prefs;
  Rect? _mainBounds;
  bool _mainWasMaximized = false;
  bool _mainWasFullScreen = false;
  bool _mainWasAlwaysOnTop = false;
  bool _mainWasSkipTaskbar = false;
  bool _active = false;
  bool _pinned = true;
  bool _transitioning = false;
  Timer? _positionSaveTimer;

  static bool get supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  bool get active => _active;
  bool get pinned => _pinned;

  void configure(AppPrefs prefs) {
    _prefs = prefs;
    final savedPinned = prefs.values['basket_pinned'];
    if (savedPinned is bool) _pinned = savedPinned;
  }

  Future<void> show({Rect? anchor}) async {
    if (!supported || _transitioning) return;
    if (_active) {
      await _revealWindow();
      return;
    }

    _transitioning = true;
    try {
      _mainWasMaximized = await windowManager.isMaximized();
      _mainWasFullScreen = await windowManager.isFullScreen();
      _mainWasAlwaysOnTop = await windowManager.isAlwaysOnTop();
      _mainWasSkipTaskbar = await windowManager.isSkipTaskbar();
      if (_mainWasFullScreen) await windowManager.setFullScreen(false);
      if (_mainWasMaximized) await windowManager.unmaximize();
      _mainBounds = await windowManager.getBounds();

      _active = true;
      notifyListeners();

      await windowManager.setMinimumSize(size);
      await windowManager.setMaximumSize(size);
      await windowManager.setResizable(false);
      await windowManager.setMaximizable(false);
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      // On macOS this call changes the whole application's activation policy
      // to NSApplication.ActivationPolicy.accessory. Doing that while handling
      // a status-item click can prevent the first left click from activating
      // the basket. The Dock entry is therefore retained on macOS; Windows and
      // Linux can safely hide the compact window from their taskbars.
      if (!Platform.isMacOS) await windowManager.setSkipTaskbar(true);
      await windowManager.setAlwaysOnTop(_pinned);
      await windowManager.setTitle('CrossTransfer');
      final position = await _basketPosition(anchor);
      await windowManager.setBounds(position & size);
      await _revealWindow();
    } catch (error) {
      debugPrint('desktop basket unavailable: $error');
      _active = false;
      notifyListeners();
      await _restoreWindowChrome();
    } finally {
      _transitioning = false;
    }
  }

  Future<void> showMain() async {
    if (!supported || _transitioning) return;
    if (!_active) {
      await _revealWindow();
      return;
    }

    _transitioning = true;
    try {
      await _savePosition();
      await _restoreWindowChrome();
      final bounds = _mainBounds;
      if (bounds != null) await windowManager.setBounds(bounds);
      if (_mainWasMaximized) await windowManager.maximize();
      if (_mainWasFullScreen) await windowManager.setFullScreen(true);
      _active = false;
      notifyListeners();
      await _revealWindow();
    } catch (error) {
      debugPrint('failed to restore main window: $error');
      _active = false;
      notifyListeners();
      await windowManager.show();
    } finally {
      _transitioning = false;
    }
  }

  Future<void> hide() async {
    if (!supported) return;
    if (_active) await _savePosition();
    await windowManager.hide();
  }

  Future<void> togglePinned() async {
    if (!supported) return;
    _pinned = !_pinned;
    notifyListeners();
    await _prefs?.set('basket_pinned', _pinned);
    if (_active) await windowManager.setAlwaysOnTop(_pinned);
  }

  void schedulePositionSave() {
    if (!_active) return;
    _positionSaveTimer?.cancel();
    _positionSaveTimer = Timer(
      const Duration(milliseconds: 350),
      _savePosition,
    );
  }

  Future<void> _restoreWindowChrome() async {
    await windowManager.setMaximumSize(_unboundedMaximumSize);
    await windowManager.setMinimumSize(_mainMinimumSize);
    await windowManager.setResizable(true);
    await windowManager.setMaximizable(true);
    await windowManager.setTitleBarStyle(
      TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
    await windowManager.setSkipTaskbar(_mainWasSkipTaskbar);
    await windowManager.setAlwaysOnTop(_mainWasAlwaysOnTop);
  }

  Future<void> _revealWindow() async {
    await windowManager.show();
    if (Platform.isMacOS) {
      // window_manager queues makeKeyAndOrderFront on the macOS main queue.
      // Yield once so that operation completes before the explicit focus call.
      await Future<void>.delayed(Duration.zero);
    }
    await windowManager.focus();
  }

  Future<Offset> _basketPosition(Rect? anchor) async {
    final topLeft = await calcWindowPosition(size, Alignment.topLeft);
    final bottomRight = await calcWindowPosition(size, Alignment.bottomRight);
    final saved = _prefs?.values['basket_position'];
    Offset? desired;
    if (saved is Map) {
      final x = saved['x'];
      final y = saved['y'];
      if (x is num && y is num) desired = Offset(x.toDouble(), y.toDouble());
    }
    if (desired == null && anchor != null && !anchor.isEmpty) {
      final above =
          anchor.center.dy > (topLeft.dy + bottomRight.dy + size.height) / 2;
      desired = Offset(
        anchor.center.dx - size.width / 2,
        above ? anchor.top - size.height - 8 : anchor.bottom + 8,
      );
    }
    desired ??= bottomRight - const Offset(16, 16);
    return Offset(
      desired.dx.clamp(topLeft.dx + 8, bottomRight.dx - 8).toDouble(),
      desired.dy.clamp(topLeft.dy + 8, bottomRight.dy - 8).toDouble(),
    );
  }

  Future<void> _savePosition() async {
    if (!_active || _prefs == null) return;
    try {
      final position = await windowManager.getPosition();
      await _prefs!.set('basket_position', {
        'x': position.dx,
        'y': position.dy,
      });
    } catch (error) {
      debugPrint('failed to save basket position: $error');
    }
  }
}
