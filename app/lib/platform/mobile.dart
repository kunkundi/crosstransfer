// Mobile integration. Providers are copied to persistent app storage for core.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MobilePlatform {
  static const channel = MethodChannel('com.crosstransfer/mobile');
  static bool get isIOS => !kIsWeb && Platform.isIOS;
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;
  static bool get isMobile => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  static String displayPath(String path) {
    final marker = path.lastIndexOf('/Documents/');
    if (isIOS && marker >= 0) return path.substring(marker + 1);
    if (isAndroid && path.contains('/app_flutter/')) {
      return path.substring(path.lastIndexOf('/app_flutter/') + 13);
    }
    return path;
  }

  static Future<void> setTransferActive(bool active) async {
    if (isMobile) await channel.invokeMethod<void>('SetTransferActive', active);
  }

  static Future<List<Map<String, dynamic>>> readInbox() async {
    if (!isMobile) return [];
    final items = await channel.invokeListMethod<dynamic>('ReadInbox');
    return (items ?? [])
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
  }

  static Future<void> acknowledgeInbox(String id) async {
    if (isMobile) await channel.invokeMethod<void>('AcknowledgeInbox', id);
  }

  static Future<void> shareLink(String link) async {
    if (isMobile) await channel.invokeMethod<void>('ShareLink', link);
  }

  static Future<String?> scanCode({
    required String title,
    required String cancel,
  }) => channel.invokeMethod<String>('ScanCode', {
    'title': title,
    'cancel': cancel,
  });

  static Future<void> cancelScan() => channel.invokeMethod<void>('CancelScan');

  static Future<Map<String, dynamic>> importStorage() async =>
      await channel.invokeMapMethod<String, dynamic>('ImportStorage') ?? {};

  static Future<Map<String, dynamic>> clearImports(List<String> ids) async =>
      await channel.invokeMapMethod<String, dynamic>('ClearImports', ids) ?? {};

  static Future<void> exportDirectory(String path) async {
    if (isMobile) await channel.invokeMethod<void>('ExportDirectory', path);
  }

  static Future<List<String>> pickAndroidFiles({bool folder = false}) async =>
      await channel.invokeListMethod<String>(
        folder ? 'PickFolder' : 'PickFiles',
      ) ??
      [];
}
