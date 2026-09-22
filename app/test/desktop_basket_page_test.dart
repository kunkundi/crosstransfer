import 'package:crosstransfer/i18n/strings.dart';
import 'package:crosstransfer/platform/desktop_basket.dart';
import 'package:crosstransfer/state/models.dart';
import 'package:crosstransfer/state/providers.dart';
import 'package:crosstransfer/ui/desktop_basket_page.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class BasketFakeCore extends CoreStateNotifier {
  BasketFakeCore({this.available = true});

  bool available;
  final requests = <List<String>>[];

  @override
  CoreState build() =>
      CoreState(config: CoreConfig({'service_available': available}));

  void setAvailable(bool value) {
    available = value;
    state = CoreState(config: CoreConfig({'service_available': value}));
  }

  @override
  String createShare(List<String> paths, {String? mode, int? ttlSec}) {
    requests.add(paths);
    const id = 'basket-share';
    state = state.copyWith(
      shares: {
        id: ShareInfo.fromJson({
          'id': id,
          'state': 'ready',
          'code': 'ABCD-EFGH12',
          'link': 'https://example.test/ABCD-EFGH12',
        }).withPaths(paths),
      },
    );
    return id;
  }
}

void main() {
  Future<void> mount(WidgetTester tester, BasketFakeCore core) async {
    tester.view.physicalSize = const Size(420, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreStateProvider.overrideWith(() => core),
          sProvider.overrideWithValue(const S('en')),
        ],
        child: const MaterialApp(home: DesktopBasketPage()),
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
    final core = BasketFakeCore();
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
    final core = BasketFakeCore(available: false);
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
    final basket = DesktopBasket.instance;
    if (!basket.pinned) await basket.togglePinned();
    addTearDown(() async {
      if (!basket.pinned) await basket.togglePinned();
    });

    await mount(tester, BasketFakeCore());

    IconButton pinButton() =>
        tester.widget<IconButton>(find.byKey(const Key('basket-pin-toggle')));

    expect(pinButton().isSelected, isTrue);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(find.byTooltip('Stop keeping on top'), findsOneWidget);

    await tester.tap(find.byKey(const Key('basket-pin-toggle')));
    await tester.pump();

    expect(pinButton().isSelected, isFalse);
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
    expect(find.byTooltip('Keep on top'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
