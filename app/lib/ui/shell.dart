// Application shell: navigation rail, pages, and the glue that turns core
// events into notifications, snack bars and tray/link behaviour.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/mobile.dart';
import '../platform/mobile_lifecycle.dart';
import '../state/format.dart';

import '../platform/links.dart';
import '../platform/notifications.dart';
import '../platform/tray.dart';
import '../state/providers.dart';
import 'receive_page.dart';
import 'send_page.dart';
import 'settings_page.dart';
import 'widgets.dart';

class CrossTransferApp extends ConsumerWidget {
  const CrossTransferApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final seed = const Color(0xFF2E6BE6);
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: b),
          useMaterial3: true,
          visualDensity: VisualDensity.compact,
        );
    return MaterialApp(
      title: s('app.title'),
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
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
      if (mounted) showSnack(context, '${ref.read(sProvider)('common.error')}: $e');
    } finally {
      _readingInbox = false;
    }
  }

  Future<void> _consumeInbox(Map<String, dynamic> item, {bool send = true}) async {
    if (_consumingInbox) return;
    setState(() => _consumingInbox = true);
    try {
      if (send) {
        if (!ref.read(coreStateProvider).serverConfigured) {
          showSnack(context, ref.read(sProvider)('send.no_server'));
          ref.read(navIndexProvider.notifier).set(2);
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
      if (mounted) showSnack(context, '${ref.read(sProvider)('common.error')}: $e');
    } finally {
      if (mounted) setState(() => _consumingInbox = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _mobile = MobileLifecycle(() {
      if (mounted) showSnack(context, ref.read(sProvider)('mobile.expired'));
    }, _readInbox, (error) {
      if (mounted) {
        showSnack(context, '${ref.read(sProvider)('common.error')}: $error');
      }
    })..start();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _mobile.update(ref.read(coreStateProvider), ref.read(coreStateProvider.notifier));
      final s = ref.read(sProvider);
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
        notifier.show(s('notify.recv_done'),
            s('notify.saved_to').replaceFirst('{dir}', r.saveDir));
      } else if (r.state == 'failed') {
        notifier.show(s('notify.recv_failed'), s.errorCode(r.errorCode));
      }
    }
    final err = next.lastError;
    if (err != null && err.seq != (prev.lastError?.seq ?? 0) && mounted) {
      showSnack(context, '${s('common.error')}: ${err.code} ${err.message}'.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sProvider);
    final index = ref.watch(navIndexProvider);
    ref.listen<CoreState>(coreStateProvider, _onCoreChange);
    ref.listen<String>(languageProvider, (_, _) {
      DesktopTray.instance.setMenu(ref.read(sProvider));
    });

    final pages = const [SendPage(), ReceivePage(), SettingsPage()];
    final page = Column(children: [
      if (MobilePlatform.isIOS && MobileLifecycle.hasActiveWork(ref.watch(coreStateProvider)))
        Padding(padding: const EdgeInsets.all(8), child: Text(s('mobile.foreground'))),
      if (_inbox.isNotEmpty)
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s('mobile.inbox')),
            Text((_inbox.first['paths'] as List).map((p) => (p as String).split('/').last).join(', '), maxLines: 2, overflow: TextOverflow.ellipsis),
            Wrap(spacing: 8, children: [
              FilledButton(onPressed: _consumingInbox ? null : () => _consumeInbox(_inbox.first), child: Text(s((_inbox.first['paths'] as List).isEmpty ? 'recv.start' : 'mobile.inbox_send'))),
              TextButton(onPressed: _consumingInbox ? null : () => _consumeInbox(_inbox.first, send: false), child: Text(s('mobile.inbox_remove'))),
            ]),
          ],
        ))),
      Expanded(child: IndexedStack(index: index, children: pages)),
    ]);
    if (MediaQuery.sizeOf(context).width < 600) {
      return Scaffold(
        appBar: AppBar(title: Text(s('app.title')), actions: const [
          Padding(padding: EdgeInsets.all(20), child: _SignalIndicator()),
        ]),
        body: SafeArea(child: page),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) => ref.read(navIndexProvider.notifier).set(i),
          destinations: [
            NavigationDestination(icon: const Icon(Icons.upload_outlined), label: s('nav.send')),
            NavigationDestination(icon: const Icon(Icons.download_outlined), label: s('nav.receive')),
            NavigationDestination(icon: const Icon(Icons.settings_outlined), label: s('nav.settings')),
          ],
        ),
      );
    }
    return Scaffold(
      body: SafeArea(child: Row(
        children: [
          NavigationRail(
            selectedIndex: index,
            onDestinationSelected: (i) => ref.read(navIndexProvider.notifier).set(i),
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.only(top: 12, bottom: 8),
              child: Icon(Icons.swap_horiz_rounded, size: 32),
            ),
            trailing: const Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: _SignalIndicator(),
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
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: page,
          ),
        ],
      )),
    );
  }
}

class _SignalIndicator extends ConsumerWidget {
  const _SignalIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sProvider);
    final state = ref.watch(coreStateProvider.select((st) => st.signalState));
    final configured = ref.watch(coreStateProvider.select((st) => st.serverConfigured));
    final cs = Theme.of(context).colorScheme;
    Color color;
    String label;
    if (!configured) {
      color = cs.outline;
      label = s('signal.unconfigured');
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
    return Tooltip(
      message: label,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
