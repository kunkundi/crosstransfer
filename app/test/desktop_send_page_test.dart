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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class DesktopFakeCore extends CoreStateNotifier {
  DesktopFakeCore({this.available = true});

  bool available;
  final requests = <List<String>>[];
  final receives = <String>[];
  final closed = <String>[];

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
  }) async {
    tester.view.physicalSize = DesktopWindow.size;
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
          theme: buildAppTheme(brightness, platform: TargetPlatform.macOS),
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
    expect(tester.getSize(find.byType(DesktopWindowFrame)), DesktopWindow.size);
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
    'window controls remain available on the about route and dialog',
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
      expect(find.byTooltip('Close window'), findsOneWidget);
      final details = find.text(const S('en')('about.version_details'));
      await tester.ensureVisible(details);
      await tester.pumpAndSettle();
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byTooltip('Close window'), findsOneWidget);
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
