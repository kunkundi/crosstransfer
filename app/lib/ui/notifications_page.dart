import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/notifications.dart';
import '../state/providers.dart';

class NotificationsPage extends ConsumerWidget {
  const NotificationsPage({super.key});

  String _date(int seconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
    String pad(int n) => '$n'.padLeft(2, '0');
    return '${date.year}-${pad(date.month)}-${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final inbox = ref.watch(notificationInboxProvider);
    final connected = ref.watch(
      coreStateProvider.select((v) => v.signalState == 'connected'),
    );
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  s('nav.notifications'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(
                onPressed: inbox.unreadCount == 0
                    ? null
                    : ref.read(notificationInboxProvider.notifier).markAllRead,
                child: Text(s('notifications.read_all')),
              ),
            ],
          ),
        ),
        if (!connected)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              s('notifications.offline'),
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        Expanded(
          child: inbox.items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.notifications_none,
                          size: 40,
                          color: colors.outline,
                        ),
                        const SizedBox(height: 12),
                        Text(s('notifications.empty')),
                        const SizedBox(height: 6),
                        Text(
                          s('notifications.empty_hint'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  itemCount: inbox.items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = inbox.items[index];
                    final unread = !inbox.read.contains(item.id);
                    final color = item.level == 'important'
                        ? colors.error
                        : colors.primary;
                    return Material(
                      key: ValueKey('notification-${item.id}'),
                      color: unread
                          ? colors.primaryContainer.withValues(alpha: 0.3)
                          : colors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          ref
                              .read(notificationInboxProvider.notifier)
                              .markRead(item.id);
                          showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(item.title),
                              content: SizedBox(
                                width: 480,
                                child: SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '${s('notifications.${item.level}')} · ${_date(item.createdAt)}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                      const SizedBox(height: 16),
                                      SelectableText(item.body),
                                    ],
                                  ),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: Text(s('notifications.close')),
                                ),
                              ],
                            ),
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  if (unread) ...[
                                    Icon(Icons.circle, size: 7, color: color),
                                    const SizedBox(width: 6),
                                  ],
                                  Expanded(
                                    child: Text(
                                      s('notifications.${item.level}'),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: color,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    _date(item.createdAt),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                item.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: unread
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                item.body,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                              if (unread)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    s('notifications.unread'),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: color,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
