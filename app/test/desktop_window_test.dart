import 'dart:io';

import 'package:crosstransfer/platform/desktop_window.dart';
import 'package:crosstransfer/state/app_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pin defaults off and preserves saved and legacy preferences', () async {
    final dir = await Directory.systemTemp.createTemp('ct-window-prefs-');
    addTearDown(() => dir.delete(recursive: true));
    final prefs = AppPrefs(dir.path);
    final window = DesktopWindow.instance;
    window.configure(prefs);
    expect(window.pinned, isFalse);
    await window.togglePinned();
    final reloaded = AppPrefs(dir.path);
    await reloaded.load();
    window.configure(reloaded);
    expect(window.pinned, isTrue);
    await window.togglePinned();
    await reloaded.load();
    expect(reloaded.values['window_pinned'], isFalse);

    await prefs.set('window_pinned', null);
    await prefs.set('basket_pinned', true);
    window.configure(prefs);
    expect(window.pinned, isTrue);
    await prefs.set('window_pinned', false);
    window.configure(prefs);
    expect(window.pinned, isFalse);
  });
}
