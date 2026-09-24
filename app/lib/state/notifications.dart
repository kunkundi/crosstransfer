import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/notifications.dart';
import 'providers.dart';
import 'notification_model.dart';

class NotificationInbox {
  const NotificationInbox({
    this.items = const [],
    this.read = const {},
    this.seen = const {},
  });
  final List<ServiceNotification> items;
  final Set<String> read;
  final Set<String> seen;
  int get unreadCount => items.where((item) => !read.contains(item.id)).length;
}

final notificationDeliveryProvider = Provider<void Function(String, String)>(
  (ref) =>
      (title, body) => unawaited(DesktopNotifier.instance.show(title, body)),
);

class NotificationInboxNotifier extends Notifier<NotificationInbox> {
  static const prefsKey = 'service_notifications';

  @override
  NotificationInbox build() {
    final cached = ref.read(appPrefsProvider).values[prefsKey];
    var initial = NotificationInbox(
      items: ServiceNotification.parseList(
        cached is Map ? cached['items'] : null,
      ),
      read: _ids(cached is Map ? cached['read'] : null),
      seen: _ids(cached is Map ? cached['seen'] : null),
    );
    final snapshot = ref.read(coreStateProvider).notifications;
    if (snapshot != null) {
      final fresh = snapshot.where((item) => !initial.seen.contains(item.id));
      if (fresh.isNotEmpty) {
        ref.read(notificationDeliveryProvider)(
          fresh.first.title,
          fresh.first.body,
        );
      }
      initial = _merge(initial, snapshot);
      _save(initial);
    }
    ref.listen<List<ServiceNotification>?>(
      coreStateProvider.select((value) => value.notifications),
      (_, next) {
        if (next != null) sync(next);
      },
    );
    return initial;
  }

  static Set<String> _ids(Object? value) =>
      value is List ? value.whereType<String>().take(200).toSet() : {};

  NotificationInbox _merge(
    NotificationInbox previous,
    List<ServiceNotification> items,
  ) {
    final active = items.map((item) => item.id).toSet();
    final seen = {...previous.seen, ...active}.toList();
    return NotificationInbox(
      items: items,
      read: previous.read.intersection(active),
      seen: seen.skip(seen.length > 200 ? seen.length - 200 : 0).toSet(),
    );
  }

  void sync(List<ServiceNotification> items) {
    final fresh = items.where((item) => !state.seen.contains(item.id)).toList();
    state = _merge(state, items);
    _save(state);
    // Reconnect may deliver many announcements; only alert for the newest one.
    if (fresh.isNotEmpty) {
      ref.read(notificationDeliveryProvider)(
        fresh.first.title,
        fresh.first.body,
      );
    }
  }

  void markRead(String id) {
    if (state.read.contains(id) || !state.items.any((item) => item.id == id)) {
      return;
    }
    state = NotificationInbox(
      items: state.items,
      read: {...state.read, id},
      seen: state.seen,
    );
    _save(state);
  }

  void markAllRead() {
    state = NotificationInbox(
      items: state.items,
      read: state.items.map((item) => item.id).toSet(),
      seen: state.seen,
    );
    _save(state);
  }

  void _save(NotificationInbox inbox) {
    unawaited(
      ref.read(appPrefsProvider).set(prefsKey, {
        'items': inbox.items.map((item) => item.toJson()).toList(),
        'read': inbox.read.toList(),
        'seen': inbox.seen.toList(),
      }),
    );
  }
}

final notificationInboxProvider =
    NotifierProvider<NotificationInboxNotifier, NotificationInbox>(
      NotificationInboxNotifier.new,
    );
