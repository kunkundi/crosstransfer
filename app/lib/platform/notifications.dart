// Desktop notifications for transfer milestones.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_linux/flutter_local_notifications_linux.dart';
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';

class DesktopNotifier {
  DesktopNotifier._();
  static final DesktopNotifier instance = DesktopNotifier._();

  static const _appleChannel = MethodChannel('com.crosstransfer/notifications');
  static const _androidChannel = MethodChannel('com.crosstransfer/mobile');
  LinuxFlutterLocalNotificationsPlugin? _linux;
  FlutterLocalNotificationsWindows? _windows;
  bool _ready = false;
  int _seq = 0;

  Future<void> init() async {
    if (kIsWeb) return;
    try {
      if (Platform.isLinux) {
        _linux = LinuxFlutterLocalNotificationsPlugin();
        _ready = await _linux!.initialize(
          settings: const LinuxInitializationSettings(
            defaultActionName: 'Open',
          ),
        ) ?? true;
      } else if (Platform.isWindows) {
        _windows = FlutterLocalNotificationsWindows();
        _ready = await _windows!.initialize(
          settings: const WindowsInitializationSettings(
            appName: 'CrossTransfer',
            appUserModelId: 'com.crosstransfer.crosstransfer',
            guid: '7e6d0d63-2f4b-4b39-9a58-3c2c3e2f1a10',
          ),
        );
      } else if (Platform.isAndroid) {
        _ready =
            await _androidChannel.invokeMethod<bool>('InitNotifications') ??
            false;
      } else if (Platform.isIOS || Platform.isMacOS) {
        _ready =
            await _appleChannel.invokeMethod<bool>('InitNotifications') ??
            false;
      }
    } catch (e) {
      debugPrint('notifications init: $e');
      _ready = false;
    }
  }

  Future<void> show(String title, String body) async {
    if (!_ready) return;
    try {
      final id = ++_seq;
      if (_linux != null) {
        await _linux!.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: const LinuxNotificationDetails(),
        );
      } else if (_windows != null) {
        await _windows!.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: const WindowsNotificationDetails(),
        );
      } else {
        await (Platform.isAndroid ? _androidChannel : _appleChannel)
            .invokeMethod<void>('ShowNotification', {
              'id': id,
              'title': title,
              'body': body,
            });
      }
    } catch (e) {
      debugPrint('notification: $e');
    }
  }

  bool get supported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isLinux;
}
