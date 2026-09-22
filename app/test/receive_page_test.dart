import 'package:crosstransfer/i18n/strings.dart';
import 'package:crosstransfer/state/models.dart';
import 'package:crosstransfer/state/providers.dart';
import 'package:crosstransfer/ui/receive_page.dart';
import 'package:crosstransfer/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCoreState extends CoreStateNotifier {
  final requests = <String>[];
  bool configured = true;

  @override
  CoreState build() => CoreState(
    config: CoreConfig({
      'save_dir': '/tmp/received',
      'service_available': configured,
    }),
  );

  @override
  String startReceive(String codeOrLink, {String? saveDir}) {
    requests.add(codeOrLink);
    return 'receive-${requests.length}';
  }
}

void main() {
  Future<ProviderContainer> mount(
    WidgetTester tester,
    FakeCoreState core, {
    bool withDesktopRail = false,
  }) async {
    final container = ProviderContainer(
      overrides: [
        coreStateProvider.overrideWith(() => core),
        sProvider.overrideWithValue(const S('en')),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(
            body: withDesktopRail
                ? const Row(
                    children: [
                      SizedBox(width: 160),
                      VerticalDivider(width: 1),
                      Expanded(child: ReceivePage()),
                    ],
                  )
                : const ReceivePage(),
          ),
        ),
      ),
    );
    return container;
  }

  testWidgets('typing a complete code submits once, incomplete input waits', (
    tester,
  ) async {
    final core = FakeCoreState();
    await mount(tester, core);
    await tester.enterText(find.byType(TextField), 'mxt3x-f8sk');
    expect(core.requests, isEmpty);
    await tester.enterText(find.byType(TextField), 'mxt3x-f8sk2');
    await tester.pump();
    expect(core.requests, ['MXT3XF8SK2']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets(
    'OS link activation starts a receive and consumes the pending code',
    (tester) async {
      final core = FakeCoreState();
      final container = await mount(tester, core);
      container.read(pendingReceiveProvider.notifier).set('MXT3XF8SK2');
      await tester.pump();
      expect(core.requests, ['MXT3XF8SK2']);
      expect(container.read(pendingReceiveProvider), isNull);
    },
  );

  testWidgets('unavailable service leaves the code available for retry', (
    tester,
  ) async {
    final core = FakeCoreState()..configured = false;
    await mount(tester, core);
    await tester.enterText(find.byType(TextField), 'MXT3XF8SK2');
    await tester.pump();
    expect(core.requests, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'MXT3XF8SK2',
    );
    expect(find.text(const S('en')('service.unavailable')), findsOneWidget);
  });

  for (final width in [375.0, 660.0]) {
    testWidgets(
      'invalid code does not move the receive controls at ${width.toInt()}px',
      (tester) async {
        tester.view.physicalSize = Size(width, width == 375 ? 812 : 430);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await mount(tester, FakeCoreState(), withDesktopRail: width == 660);
        final input = find.byType(TextField);
        final button = find.text(const S('en')('recv.start')).last;
        final saveTo = find.text('${const S('en')('recv.save_to')}: ');
        final inputRect = tester.getRect(input);
        final buttonRect = tester.getRect(button);
        final saveToRect = tester.getRect(saveTo);

        await tester.enterText(input, 'not-a-link');
        await tester.tap(button);
        await tester.pump();

        expect(find.text(const S('en')('recv.invalid')), findsOneWidget);
        expect(tester.getRect(input), inputRect);
        expect(tester.getRect(button), buttonRect);
        expect(tester.getRect(saveTo), saveToRect);
        expect(tester.takeException(), isNull);

        await tester.enterText(input, 'retry');
        await tester.pump();
        expect(find.text(const S('en')('recv.invalid')), findsNothing);
        expect(tester.getRect(input), inputRect);
        expect(tester.getRect(button), buttonRect);
        expect(tester.getRect(saveTo), saveToRect);
      },
    );
  }
}
