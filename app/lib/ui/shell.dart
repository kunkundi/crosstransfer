// Application shell: navigation rail, pages, and the glue that turns core
// events into notifications, snack bars and tray/link behaviour.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/links.dart';
import '../platform/desktop_menu.dart';
import '../platform/mobile.dart';
import '../platform/mobile_lifecycle.dart';
import '../platform/notifications.dart';
import '../platform/tray.dart';
import '../state/format.dart';
import '../state/providers.dart';
import '../state/notifications.dart';
import 'notifications_page.dart';
import 'desktop_send_page.dart';
import 'desktop_layout.dart';
import 'receive_page.dart';
import 'send_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'widgets.dart';

class CrossTransferApp extends ConsumerWidget {
  const CrossTransferApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    return MaterialApp(
      title: s('app.title'),
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      builder: (context, child) => isDesktopTheme(context)
          ? Overlay.wrap(
              child: DesktopWindowFrame(
                strings: s,
                status: const _SignalIndicator(showLabel: true),
                child: child!,
              ),
            )
          : child!,
      home: const Shell(),
    );
  }
}

class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});

  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  late final MobileLifecycle _mobile;
  List<Map<String, dynamic>> _inbox = [];
  bool _readingInbox = false;
  bool _consumingInbox = false;

  Future<void> _readInbox() async {
    if (_readingInbox || !mounted) return;
    _readingInbox = true;
    try {
      final inbox = await MobilePlatform.readInbox();
      if (mounted) setState(() => _inbox = inbox);
    } catch (e) {
      if (mounted) {
        showSnack(context, '${ref.read(sProvider)('common.error')}: $e');
      }
    } finally {
      _readingInbox = false;
    }
  }

  Future<void> _consumeInbox(
    Map<String, dynamic> item, {
    bool send = true,
  }) async {
    if (_consumingInbox) return;
    setState(() => _consumingInbox = true);
    try {
      if (send) {
        if (!ref.read(coreStateProvider).serviceAvailable) {
          showSnack(context, ref.read(sProvider)('service.unavailable'));
          return;
        }
        final paths = (item['paths'] as List).cast<String>();
        final code = extractTakeCode(item['content'] as String? ?? '');
        if (paths.isNotEmpty) {
          ref.read(coreStateProvider.notifier).createShare(paths);
          ref.read(navIndexProvider.notifier).set(0);
        } else if (code != null) {
          ref.read(pendingReceiveProvider.notifier).set(code);
          ref.read(navIndexProvider.notifier).set(1);
        } else {
          showSnack(context, ref.read(sProvider)('recv.invalid'));
          return;
        }
      }
      await MobilePlatform.acknowledgeInbox(item['id'] as String);
      await _readInbox();
    } catch (e) {
      if (mounted) {
        showSnack(context, '${ref.read(sProvider)('common.error')}: $e');
      }
    } finally {
      if (mounted) setState(() => _consumingInbox = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _mobile = MobileLifecycle(
      () {
        if (mounted) showSnack(context, ref.read(sProvider)('mobile.expired'));
      },
      _readInbox,
      (error) {
        if (mounted) {
          showSnack(context, '${ref.read(sProvider)('common.error')}: $error');
        }
      },
    )..start();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _mobile.update(
        ref.read(coreStateProvider),
        ref.read(coreStateProvider.notifier),
      );
      final s = ref.read(sProvider);
      await DesktopMenu.start(s, (index) {
        if (!mounted) return;
        Navigator.of(context).popUntil((route) => route.isFirst);
        ref.read(navIndexProvider.notifier).set(index);
      });
      if (!mounted) return;
      await DesktopTray.instance.install(s);
      if (!mounted) return;
      await LinkHandler.instance.start((code) {
        if (!mounted) return;
        ref.read(pendingReceiveProvider.notifier).set(code);
        ref.read(navIndexProvider.notifier).set(1);
        DesktopTray.instance.showWindow();
      });
      await _readInbox();
    });
  }

  @override
  void dispose() {
    _mobile.dispose();
    DesktopMenu.stop();
    LinkHandler.instance.stop();
    super.dispose();
  }

  void _onCoreChange(CoreState? prev, CoreState next) {
    _mobile.update(next, ref.read(coreStateProvider.notifier));
    if (prev == null) return;
    final s = ref.read(sProvider);
    final notifier = DesktopNotifier.instance;

    for (final share in next.shares.values) {
      final p = prev.shares[share.id];
      if (p == null) continue;
      if (p.state == 'ready' && share.state == 'claimed') {
        notifier.show(s('notify.share_claimed'), share.code);
      }
      if (share.completed > p.completed) {
        notifier.show(s('notify.send_done'), share.code);
      }
    }
    for (final r in next.receives.values) {
      final p = prev.receives[r.transferId];
      if (p == null || p.state == r.state) continue;
      if (r.state == 'completed') {
        notifier.show(
          s('notify.recv_done'),
          s('notify.saved_to').replaceFirst('{dir}', r.saveDir),
        );
      } else if (r.state == 'failed') {
        notifier.show(s('notify.recv_failed'), s.errorCode(r.errorCode));
      }
    }
    final err = next.lastError;
    if (err != null && err.seq != (prev.lastError?.seq ?? 0) && mounted) {
      showSnack(context, s.errorCode(err.code));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sProvider);
    final index = ref.watch(navIndexProvider);
    final unread = ref.watch(
      notificationInboxProvider.select((v) => v.unreadCount),
    );
    ref.listen<CoreState>(coreStateProvider, _onCoreChange);
    ref.listen<String>(languageProvider, (_, _) {
      DesktopTray.instance.setMenu(ref.read(sProvider));
      DesktopMenu.update(ref.read(sProvider));
    });

    final pages = [
      isDesktopTheme(context) ? const DesktopSendPage() : const SendPage(),
      const ReceivePage(),
      const SettingsPage(),
      const NotificationsPage(),
    ];
    final page = Column(
      children: [
        if (MobilePlatform.isIOS &&
            MobileLifecycle.hasActiveWork(ref.watch(coreStateProvider)))
          _NoticeBanner(icon: Icons.phone_iphone, text: s('mobile.foreground')),
        if (_inbox.isNotEmpty)
          _InboxBanner(
            item: _inbox.first,
            busy: _consumingInbox,
            onConsume: () => _consumeInbox(_inbox.first),
            onRemove: () => _consumeInbox(_inbox.first, send: false),
          ),
        Expanded(
          child: IndexedStack(index: index, children: pages),
        ),
      ],
    );
    if (isDesktopTheme(context)) {
      return Scaffold(
        body: SafeArea(
          child: DesktopLayout(
            strings: s,
            selectedIndex: index,
            notificationCount: unread,
            onSelected: (i) => ref.read(navIndexProvider.notifier).set(i),
            child: page,
          ),
        ),
      );
    }
    if (MediaQuery.sizeOf(context).width < 600) {
      return Scaffold(
        appBar: AppBar(
          toolbarHeight: 62,
          titleSpacing: 18,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppMark(size: 30),
              const SizedBox(width: 10),
              Text(s('app.title')),
            ],
          ),
          actions: const [
            Padding(
              padding: EdgeInsets.only(right: 18),
              child: _SignalIndicator(),
            ),
          ],
        ),
        body: SafeArea(child: page),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) =>
              ref.read(navIndexProvider.notifier).set(i),
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.upload_outlined),
              label: s('nav.send'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.download_outlined),
              label: s('nav.receive'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              label: s('nav.settings'),
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: unread > 0,
                label: Text('$unread'),
                child: const Icon(Icons.notifications_outlined),
              ),
              label: s('nav.notifications'),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: (i) =>
                  ref.read(navIndexProvider.notifier).set(i),
              extended: true,
              minExtendedWidth: 160,
              groupAlignment: -0.72,
              leading: Padding(
                padding: const EdgeInsets.fromLTRB(10, 14, 6, 20),
                child: Row(
                  children: [
                    const AppMark(size: 26),
                    const SizedBox(width: 6),
                    Text(
                      s('app.title'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ],
                ),
              ),
              trailing: const Expanded(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 8, 18),
                    child: _SignalIndicator(showLabel: true),
                  ),
                ),
              ),
              destinations: [
                NavigationRailDestination(
                  icon: const Icon(Icons.upload_outlined),
                  selectedIcon: const Icon(Icons.upload),
                  label: Text(s('nav.send')),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.download_outlined),
                  selectedIcon: const Icon(Icons.download),
                  label: Text(s('nav.receive')),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.settings_outlined),
                  selectedIcon: const Icon(Icons.settings),
                  label: Text(s('nav.settings')),
                ),
                NavigationRailDestination(
                  icon: Badge(
                    isLabelVisible: unread > 0,
                    label: Text('$unread'),
                    child: const Icon(Icons.notifications_outlined),
                  ),
                  label: Text(s('nav.notifications')),
                ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: page),
          ],
        ),
      ),
    );
  }
}

class _SignalIndicator extends ConsumerWidget {
  const _SignalIndicator({this.showLabel = false});

  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final state = ref.watch(coreStateProvider.select((st) => st.signalState));
    final configured = ref.watch(
      coreStateProvider.select((st) => st.serviceAvailable),
    );
    final cs = Theme.of(context).colorScheme;
    Color color;
    String label;
    if (!configured) {
      color = cs.outline;
      label = s('signal.unavailable');
    } else {
      switch (state) {
        case 'connected':
          color = Colors.green.shade600;
        case 'connecting':
        case 'reconnecting':
          color = Colors.orange.shade700;
        default:
          color = cs.error;
      }
      label = s('signal.$state');
    }
    final dot = Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    return Tooltip(
      message: label,
      child: showLabel
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                dot,
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            )
          : Semantics(label: label, child: dot),
    );
  }
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _InboxBanner extends ConsumerWidget {
  const _InboxBanner({
    required this.item,
    required this.busy,
    required this.onConsume,
    required this.onRemove,
  });

  final Map<String, dynamic> item;
  final bool busy;
  final VoidCallback onConsume;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final colors = Theme.of(context).colorScheme;
    final paths = (item['paths'] as List).cast<String>();
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.move_to_inbox_outlined,
                color: colors.onPrimaryContainer,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s('mobile.inbox'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    paths.map((path) => path.split('/').last).join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: busy ? null : onRemove,
              child: Text(s('mobile.inbox_remove')),
            ),
            FilledButton(
              onPressed: busy ? null : onConsume,
              child: Text(
                s(paths.isEmpty ? 'recv.start' : 'mobile.inbox_send'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
