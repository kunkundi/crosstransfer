import 'dart:io';

import 'package:crosstransfer/state/app_prefs.dart';
import 'package:crosstransfer/state/notifications.dart';
import 'package:crosstransfer/state/notification_model.dart';
import 'package:crosstransfer/state/providers.dart';
import 'package:crosstransfer/ui/notifications_page.dart';
import 'package:crosstransfer/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryPrefs extends AppPrefs {
  MemoryPrefs() : super('unused');
  @override
  Future<void> set(String key, Object? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

class FakeCore extends CoreStateNotifier {
  @override
  CoreState build() => const CoreState(signalState: 'connected');
  void snapshot(List<ServiceNotification> items) =>
      state = state.copyWith(notifications: items);
}

ServiceNotification item(String digit, {String? title}) => ServiceNotification(
  id: List.filled(32, digit).join(),
  title: title ?? '服务维护安排',
  body: '我们将在今晚更新服务。\n已有通知可在离线时查看。',
  level: 'important',
  createdAt: 1750000000,
);

void main() {
  late Directory dir;
  late AppPrefs prefs;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ct-notifications-');
    prefs = AppPrefs(dir.path);
    await prefs.set('language', 'zh');
  });
  tearDown(() async {
    // Queue a final write to wait for all previously scheduled preference saves.
    await prefs.set('test_barrier', true);
    await dir.delete(recursive: true);
  });

  test('push, reconnect deduplication, read persistence, revocation and offline cache', () async {
    final delivered = <String>[];
    final container = ProviderContainer(
      overrides: [
        appPrefsProvider.overrideWithValue(prefs),
        coreStateProvider.overrideWith(FakeCore.new),
        notificationDeliveryProvider.overrideWithValue(
          (title, body) => delivered.add(title),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(notificationInboxProvider, (_, _) {});
    addTearDown(subscription.close);
    final core = container.read(coreStateProvider.notifier) as FakeCore;
    core.snapshot([item('a'), item('b')]);
    expect(container.read(notificationInboxProvider).unreadCount, 2);
    expect(delivered.length, 1); // One alert for a catch-up batch.
    core.snapshot([item('a'), item('b')]);
    expect(delivered.length, 1);
    container.read(notificationInboxProvider.notifier).markRead(item('a').id);
    expect(container.read(notificationInboxProvider).unreadCount, 1);
    await prefs.set(
      'language',
      'en',
    ); // Concurrent saves must preserve both values.
    final saved = AppPrefs(dir.path);
    await saved.load();
    final restarted = ProviderContainer(
      overrides: [
        appPrefsProvider.overrideWithValue(saved),
        coreStateProvider.overrideWith(FakeCore.new),
        notificationDeliveryProvider.overrideWithValue(
          (title, body) => delivered.add(title),
        ),
      ],
    );
    addTearDown(restarted.dispose);
    expect(restarted.read(notificationInboxProvider).items.length, 2);
    expect(restarted.read(notificationInboxProvider).unreadCount, 1);
    expect(saved.language, 'en');
    (restarted.read(coreStateProvider.notifier) as FakeCore).snapshot([
      item('a'),
      item('b'),
    ]);
    expect(delivered.length, 1); // No duplicate after restarting the app.
    core.snapshot([item('b')]); // Revoked item disappears.
    expect(
      container.read(notificationInboxProvider).items.single.id,
      item('b').id,
    );
    container.read(notificationInboxProvider.notifier).markAllRead();
    expect(container.read(notificationInboxProvider).unreadCount, 0);
    core.snapshot([]);
    expect(container.read(notificationInboxProvider).items, isEmpty);
    await saved.set('test_barrier', true);
  });

  test('invalid, duplicate and revoked announcements are ignored', () {
    final valid = item('a').toJson();
    expect(
      ServiceNotification.parseList([
        valid,
        valid,
        {...valid, 'id': 'invalid'},
        {...item('b').toJson(), 'revoked_at': 10},
        {...item('c').toJson(), 'created_at': 'bad'},
        {...item('d').toJson(), 'body': ''},
        {...item('e').toJson(), 'created_at': 90000000000000},
      ]).map((v) => v.id),
      [item('a').id],
    );
  });

  for (final language in ['zh', 'en']) {
    for (final size in [const Size(380, 390), const Size(320, 600)]) {
      testWidgets('notification list and detail fit $language $size', (
        tester,
      ) async {
        final widgetPrefs = MemoryPrefs();
        widgetPrefs.values['language'] = language;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final notice = item('a', title: '服务维护与版本更新通知 Service maintenance');
        widgetPrefs.values[NotificationInboxNotifier.prefsKey] = {
          'items': [notice.toJson()],
        };
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appPrefsProvider.overrideWithValue(widgetPrefs),
              coreStateProvider.overrideWith(FakeCore.new),
              notificationDeliveryProvider.overrideWithValue((_, _) {}),
            ],
            child: MaterialApp(
              theme: buildAppTheme(Brightness.light),
              home: const Scaffold(body: SafeArea(child: NotificationsPage())),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(language == 'zh' ? '未读' : 'Unread'), findsOneWidget);
        await tester.tap(find.byKey(ValueKey('notification-${notice.id}')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(SelectableText), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(language == 'zh' ? '关闭' : 'Close'));
        await tester.pumpAndSettle();
        expect(find.text(language == 'zh' ? '未读' : 'Unread'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
