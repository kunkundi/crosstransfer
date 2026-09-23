import 'package:crosstransfer/i18n/strings.dart';
import 'package:crosstransfer/state/models.dart';
import 'package:crosstransfer/state/providers.dart';
import 'package:crosstransfer/ui/receive_page.dart';
import 'package:crosstransfer/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCoreState extends CoreStateNotifier {
  final requests = <String>[];
  bool configured = true;
  int historyCount = 0;

  @override
  CoreState build() => CoreState(
    config: CoreConfig({
      'save_dir': '/tmp/received',
      'service_available': configured,
    }),
    receives: {
      for (var index = 0; index < historyCount; index++)
        'receive-$index': ReceiveInfo.fromJson({
          'transfer_id': 'receive-$index',
          'state': 'completed',
          'code': 'MXT3XF8SK2',
          'save_dir': '/tmp/received',
          'meta': {'name': 'file-$index.txt'},
          'created_at': historyCount - index,
        }),
    },
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
    TargetPlatform? platform,
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
          theme: buildAppTheme(Brightness.light, platform: platform),
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

  testWidgets('desktop receive input stays visible while history scrolls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 382);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(
      tester,
      FakeCoreState()..historyCount = 12,
      platform: TargetPlatform.macOS,
    );
    final input = find.byType(TextField);
    final folder = find.byKey(const Key('receive-save-location'));
    final inputRect = tester.getRect(input);
    final folderRect = tester.getRect(folder);
    await tester.scrollUntilVisible(
      find.text('file-9.txt'),
      200,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey('receive-history')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(tester.getRect(input), inputRect);
    expect(tester.getRect(folder), folderRect);
    expect(find.byTooltip('/tmp/received'), findsOneWidget);
    expect(input.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  testWidgets(
    'desktop typing waits for Enter or Receive and paste is explicit',
    (tester) async {
      final core = FakeCoreState();
      await mount(tester, core, platform: TargetPlatform.macOS);
      final input = find.byType(TextField);
      await tester.enterText(input, 'MXT3X-F8SK2');
      await tester.pump();
      expect(core.requests, isEmpty);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(core.requests, ['MXT3XF8SK2']);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      await tester.enterText(input, 'https://example.test/r/MXT3XF8SK2');
      expect(core.requests.length, 1);
      await tester.tap(find.text('Receive'));
      await tester.pump();
      expect(core.requests.length, 2);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return {'text': 'https://example.test/r/MXT3XF8SK2'};
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
      await tester.tap(find.text('Paste & receive'));
      await tester.pumpAndSettle();
      expect(core.requests, List.filled(3, 'MXT3XF8SK2'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop submission failure preserves the input for retry', (
    tester,
  ) async {
    final core = FakeCoreState()..configured = false;
    await mount(tester, core, platform: TargetPlatform.macOS);
    await tester.enterText(find.byType(TextField), 'MXT3XF8SK2');
    await tester.tap(find.text('Receive'));
    await tester.pump();
    expect(core.requests, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'MXT3XF8SK2',
    );
    expect(find.text(const S('en')('service.unavailable')), findsOneWidget);
  });

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
