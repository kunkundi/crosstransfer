import 'dart:ui' show PointerDeviceKind;

import 'package:crosstransfer/i18n/strings.dart';
import 'package:crosstransfer/platform/desktop_window.dart';
import 'package:crosstransfer/state/models.dart';
import 'package:crosstransfer/state/providers.dart';
import 'package:crosstransfer/ui/desktop_send_page.dart';
import 'package:crosstransfer/ui/theme.dart';
import 'package:crosstransfer/ui/desktop_layout.dart';
import 'package:crosstransfer/ui/receive_page.dart';
import 'package:crosstransfer/ui/settings_page.dart';
import 'package:crosstransfer/ui/about_page.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

class DesktopFakeCore extends CoreStateNotifier {
  DesktopFakeCore({this.available = true});

  bool available;
  final requests = <List<String>>[];
  final receives = <String>[];
  final closed = <String>[];
  final cancelled = <String>[];

  void setTransfers(List<TransferInfo> transfers) {
    state = state.copyWith(
      transfers: {
        for (final transfer in transfers) transfer.transferId: transfer,
      },
    );
  }

  void setExpiry(int expiry) {
    const id = 'desktop-share';
    state = state.copyWith(
      shares: {
        id: ShareInfo.fromJson({
          'id': id,
          'state': 'ready',
          'mode': 'once',
          'code': 'ABCD-EFGH12',
          'link': 'https://example.test/r/ABCD-EFGH12',
          'expires_at': expiry,
        }, previous: state.shares[id]),
      },
    );
  }

  @override
  void cancelTransfer(String id) => cancelled.add(id);

  @override
  String startReceive(String codeOrLink, {String? saveDir}) {
    receives.add(codeOrLink);
    return 'receive';
  }

  @override
  void closeShare(String id) {
    closed.add(id);
    state = state.copyWith(
      shares: {
        id: ShareInfo.fromJson({
          'id': id,
          'state': 'closed',
        }, previous: state.shares[id]),
      },
    );
  }

  @override
  CoreState build() => CoreState(
    config: CoreConfig({
      'service_available': available,
      'save_dir': '/tmp/received',
    }),
  );

  void setAvailable(bool value) {
    available = value;
    state = CoreState(config: CoreConfig({'service_available': value}));
  }

  void failShare() {
    const id = 'desktop-share';
    state = state.copyWith(
      shares: {
        id: ShareInfo.fromJson({
          'id': id,
          'state': 'failed',
          'error': 'signal',
        }, previous: state.shares[id]),
      },
    );
  }

  @override
  String createShare(List<String> paths, {String? mode, int? ttlSec}) {
    requests.add(paths);
    const id = 'desktop-share';
    state = state.copyWith(
      shares: {
        id: ShareInfo.fromJson({
          'id': id,
          'state': 'ready',
          'mode': 'once',
          'code': 'ABCD-EFGH12',
          'link': 'https://example.test/ABCD-EFGH12',
        }).withPaths(paths),
      },
    );
    return id;
  }
}

class _FakeLanguage extends LanguageNotifier {
  @override
  String build() => 'en';
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    DesktopFakeCore core, {
    String language = 'en',
    Brightness brightness = Brightness.light,
    double scale = 1,
    TargetPlatform platform = TargetPlatform.macOS,
  }) async {
    tester.view.physicalSize = Size(
      DesktopWindow.size.width,
      DesktopWindow.size.height - 38,
    );
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreStateProvider.overrideWith(() => core),
          languageProvider.overrideWith(_FakeLanguage.new),
          sProvider.overrideWithValue(S(language)),
        ],
        child: MaterialApp(
          theme: buildAppTheme(brightness, platform: platform),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: Overlay.wrap(
              child: DesktopWindowFrame(
                strings: S(language),
                status: const SizedBox(width: 6, height: 6),
                child: child!,
              ),
            ),
          ),
          home: Consumer(
            builder: (context, ref, _) {
              final index = ref.watch(navIndexProvider);
              return DesktopLayout(
                strings: S(language),
                selectedIndex: index,
                onSelected: ref.read(navIndexProvider.notifier).set,
                child: IndexedStack(
                  index: index,
                  children: const [
                    DesktopSendPage(),
                    ReceivePage(),
                    SettingsPage(),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  DropDoneDetails dropped(List<String> paths) => DropDoneDetails(
    files: paths.map(DropItemFile.new).toList(),
    localPosition: Offset.zero,
    globalPosition: Offset.zero,
  );

  testWidgets('dropped files create a share and expose its take code', (
    tester,
  ) async {
    final core = DesktopFakeCore();
    await mount(tester, core);

    tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
      dropped(['/tmp/alpha.txt', '/tmp/photos']),
    );
    await tester.pumpAndSettle();

    expect(core.requests, [
      ['/tmp/alpha.txt', '/tmp/photos'],
    ]);
    expect(find.text('ABCD-EFGH12'), findsOneWidget);
    expect(find.text('Copy code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable service retains the selection for retry', (
    tester,
  ) async {
    final core = DesktopFakeCore(available: false);
    await mount(tester, core);

    tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
      dropped(['/tmp/keep-me.txt']),
    );
    await tester.pumpAndSettle();

    expect(core.requests, isEmpty);
    expect(find.text('keep-me.txt'), findsOneWidget);
    expect(find.text(const S('en')('service.unavailable')), findsOneWidget);

    core.setAvailable(true);
    await tester.pump();
    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(core.requests, [
      ['/tmp/keep-me.txt'],
    ]);
    expect(find.text('ABCD-EFGH12'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'current share shows live progress and cancels only its transfer',
    (tester) async {
      final core = DesktopFakeCore();
      await mount(tester, core);
      tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
        dropped(['/tmp/alpha.txt']),
      );
      await tester.pumpAndSettle();
      TransferInfo transfer(
        String id,
        String share,
        int done, {
        String state = 'transferring',
      }) => TransferInfo.fromJson({
        'transfer_id': id,
        'share_id': share,
        'role': 'sender',
        'state': state,
        'bytes_total': 104857600,
        'bytes_done': done,
        'rate_bps': 8388608,
        'eta_sec': 50,
      });
      core.setTransfers([
        transfer('first', 'desktop-share', 52428800),
        transfer('second', 'desktop-share', 26214400),
        transfer('other', 'other-share', 1048576),
      ]);
      await tester.pump();
      expect(find.text('50.0%'), findsOneWidget);
      expect(find.text('25.0%'), findsOneWidget);
      expect(find.text('1.0 MiB/s'), findsNWidgets(2));
      expect(find.text('ETA 50s'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('sending-other')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('cancel-first')));
      await tester.tap(find.byKey(const ValueKey('cancel-first')));
      expect(core.cancelled, ['first']);
      expect(core.closed, isEmpty);
      core.setTransfers([
        transfer('first', 'desktop-share', 104857600, state: 'completed'),
      ]);
      await tester.pump();
      expect(find.text('100.0%'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.byKey(const ValueKey('cancel-first')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('copy feedback stays in place and QR follows share expiry', (
    tester,
  ) async {
    final core = DesktopFakeCore();
    await mount(tester, core);
    tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
      dropped(['/tmp/alpha.txt']),
    );
    await tester.pumpAndSettle();
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final copy = find.byKey(const Key('share-copy-code'));
    final rect = tester.getRect(copy);
    final againRect = tester.getRect(find.text(const S('en')('send.again')));
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(clipboard, ['ABCD-EFGH12']);
    expect(find.text('Copied'), findsOneWidget);
    expect(tester.getRect(copy), rect);
    expect(tester.getRect(find.text(const S('en')('send.again'))), againRect);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Copied'), findsNothing);
    expect(find.text('Copy code'), findsOneWidget);

    core.setExpiry(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120);
    await tester.pump();
    expect(find.textContaining('Expires in'), findsOneWidget);
    await tester.tap(find.byKey(const Key('share-show-qr')));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    core.setExpiry(DateTime.now().millisecondsSinceEpoch ~/ 1000 - 1);
    await tester.pump();
    expect(find.byType(QrImageView), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Expired'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(copy).onPressed, isNull);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('share-show-qr')))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pin button immediately reflects the selected state', (
    tester,
  ) async {
    final window = DesktopWindow.instance;
    if (!window.pinned) await window.togglePinned();
    addTearDown(() async {
      if (!window.pinned) await window.togglePinned();
    });

    await mount(tester, DesktopFakeCore());

    IconButton pinButton() =>
        tester.widget<IconButton>(find.byKey(const Key('window-pin-toggle')));

    expect(pinButton().isSelected, isTrue);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(find.byTooltip('Stop keeping on top'), findsOneWidget);

    await tester.tap(find.byKey(const Key('window-pin-toggle')));
    await tester.pump();

    expect(pinButton().isSelected, isFalse);
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
    expect(find.byTooltip('Keep on top'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('desktop shortcuts preserve input on ${platform.name}', (
      tester,
    ) async {
      await mount(tester, DesktopFakeCore(), platform: platform);
      await tester.pump();
      final modifier = platform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      Future<void> shortcut(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
      }

      await shortcut(LogicalKeyboardKey.digit2);
      await tester.enterText(find.byType(TextField), 'ABCD');
      await shortcut(LogicalKeyboardKey.comma);
      expect(find.byKey(const Key('settings-ttl')), findsOneWidget);
      await shortcut(LogicalKeyboardKey.digit1);
      expect(find.text('Choose files'), findsOneWidget);
      await shortcut(LogicalKeyboardKey.digit2);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'ABCD',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('preference menus select values and dismiss with Escape', (
    tester,
  ) async {
    await mount(tester, DesktopFakeCore());
    await tester.tap(find.byKey(const ValueKey('desktop-tab-2')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-share-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Open'));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-share-mode')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mouse clicks switch tabs across the full visible segment', (
    tester,
  ) async {
    await mount(tester, DesktopFakeCore());
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopLayout)),
    );
    for (final fraction in [0.08, 0.5, 0.92]) {
      for (final index in [1, 2, 0]) {
        final rect = tester.getRect(find.byKey(ValueKey('desktop-tab-$index')));
        await tester.tapAt(
          Offset(rect.left + rect.width * fraction, rect.center.dy),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(container.read(navIndexProvider), index);
      }
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'switching tabs preserves the share and unfinished receive input',
    (tester) async {
      final core = DesktopFakeCore();
      await mount(tester, core);
      tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
        dropped(['/tmp/keep.txt']),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('desktop-tab-1')));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'ABCD');
      await tester.tap(find.byKey(const ValueKey('desktop-tab-2')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('desktop-tab-0')));
      await tester.pump();
      expect(find.text('ABCD-EFGH12'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desktop-tab-1')));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'ABCD',
      );
      expect(core.receives, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an OS take-code is consumed in the same compact window', (
    tester,
  ) async {
    final core = DesktopFakeCore();
    await mount(tester, core);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopLayout)),
    );
    container.read(navIndexProvider.notifier).set(1);
    container.read(pendingReceiveProvider.notifier).set('MXT3XF8SK2');
    await tester.pump();
    expect(core.receives, ['MXT3XF8SK2']);
    expect(container.read(pendingReceiveProvider), isNull);
    expect(
      tester.getSize(find.byType(DesktopWindowFrame)),
      Size(DesktopWindow.size.width, DesktopWindow.size.height - 38),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('sent files retain the controls to close an active share', (
    tester,
  ) async {
    final core = DesktopFakeCore();
    await mount(tester, core);
    tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
      dropped(['/tmp/history.txt']),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sent files · 1'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.ensureVisible(find.byTooltip('Close share'));
    await tester.tap(find.byTooltip('Close share'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(core.closed, ['desktop-share']);
    await tester.tap(find.text('Share again'));
    await tester.pump();
    expect(find.text('Closed'), findsOneWidget);
    expect(find.text('Copy code'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'pin remains available on routes and dialogs without duplicate OS controls',
    (tester) async {
      await mount(tester, DesktopFakeCore());
      final context = tester.element(find.byType(DesktopLayout));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const AboutPage(
            strings: S('en'),
            version: '0.1.0',
            coreVersion: 'test',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('window-pin-toggle')), findsOneWidget);
      expect(find.byTooltip('Close window'), findsNothing);
      final details = find.text(const S('en')('about.version_details'));
      await tester.ensureVisible(details);
      await tester.pumpAndSettle();
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byKey(const Key('window-pin-toggle')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in S.supported) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 1.5]) {
        testWidgets(
          'unified window fits $language ${brightness.name} at $scale',
          (tester) async {
            final core = DesktopFakeCore();
            final s = S(language);
            await mount(
              tester,
              core,
              language: language,
              brightness: brightness,
              scale: scale,
            );
            expect(tester.takeException(), isNull);
            expect(
              tester.getRect(find.text(s('send.pick_files'))).bottom,
              lessThan(tester.getRect(find.text(s('send.pick_folder'))).top),
            );

            tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
              dropped(['/tmp/A long filename 设计资料.zip', '/tmp/Photos']),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text('ABCD-EFGH12'), findsOneWidget);
            expect(
              tester.getRect(find.text(s('send.copy_code'))).bottom,
              lessThan(tester.getRect(find.text(s('send.copy_link'))).top),
            );
            await tester.ensureVisible(find.byKey(const Key('share-show-qr')));
            await tester.tap(find.byKey(const Key('share-show-qr')));
            await tester.pumpAndSettle();
            expect(find.byType(QrImageView), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.tap(find.text(s('common.close')));
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text(s('send.again')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);

            core.failShare();
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.ensureVisible(find.text(s('send.try_again')));
            await tester.tap(find.text(s('send.try_again')));
            await tester.pumpAndSettle();
            expect(find.text(s('send.pick_files')), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
