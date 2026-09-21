// Desktop notifications for transfer milestones.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class DesktopNotifier {
  DesktopNotifier._();
  static final DesktopNotifier instance = DesktopNotifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _seq = 0;

  Future<void> init() async {
    if (kIsWeb) return;
    try {
      final ok = await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_transfer'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: true,
            requestSoundPermission: true,
            requestBadgePermission: false,
          ),
          macOS: DarwinInitializationSettings(
            requestAlertPermission: true,
            requestSoundPermission: true,
            requestBadgePermission: false,
          ),
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
          windows: WindowsInitializationSettings(
            appName: 'CrossTransfer',
            appUserModelId: 'com.crosstransfer.crosstransfer',
            guid: '7e6d0d63-2f4b-4b39-9a58-3c2c3e2f1a10',
          ),
        ),
      );
      _ready = ok ?? true;
    } catch (e) {
      debugPrint('notifications init: $e');
      _ready = false;
    }
  }

  Future<void> show(String title, String body) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: ++_seq,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'milestones',
            'Transfer results',
            importance: Importance.defaultImportance,
          ),
          iOS: DarwinNotificationDetails(presentSound: true),
          macOS: DarwinNotificationDetails(presentSound: true),
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
      );
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
