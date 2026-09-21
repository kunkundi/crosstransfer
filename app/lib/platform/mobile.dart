// Mobile integration. iOS imports copies into Documents before core opens them.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MobilePlatform {
  static const channel = MethodChannel('com.crosstransfer/mobile');
  static bool get isIOS => !kIsWeb && Platform.isIOS;
  static bool get isMobile => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  static String displayPath(String path) {
    final marker = path.lastIndexOf('/Documents/');
    return isIOS && marker >= 0 ? path.substring(marker + 1) : path;
  }

  static Future<void> setTransferActive(bool active) async {
    if (isIOS) await channel.invokeMethod<void>('SetTransferActive', active);
  }

  static Future<List<Map<String, dynamic>>> readInbox() async {
    if (!isIOS) return [];
    final items = await channel.invokeListMethod<dynamic>('ReadInbox');
    return (items ?? [])
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
  }

  static Future<void> acknowledgeInbox(String id) async {
    if (isIOS) await channel.invokeMethod<void>('AcknowledgeInbox', id);
  }

  static Future<void> shareLink(String link) async {
    if (isIOS) await channel.invokeMethod<void>('ShareLink', link);
  }

  static Future<void> exportDirectory(String path) async {
    if (isIOS) await channel.invokeMethod<void>('ExportDirectory', path);
  }
}
