import 'package:crosstransfer/i18n/strings.dart';
import 'package:crosstransfer/state/models.dart';
import 'package:crosstransfer/state/providers.dart';
import 'package:crosstransfer/ui/receive_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCoreState extends CoreStateNotifier {
  final requests = <String>[];
  bool configured = true;

  @override
  CoreState build() => CoreState(config: CoreConfig({
        'save_dir': '/tmp/received',
        'service_available': configured,
      }));

  @override
  String startReceive(String codeOrLink, {String? saveDir}) {
    requests.add(codeOrLink);
    return 'receive-${requests.length}';
  }
}

void main() {
  Future<ProviderContainer> mount(WidgetTester tester, FakeCoreState core) async {
    final container = ProviderContainer(overrides: [
      coreStateProvider.overrideWith(() => core),
      sProvider.overrideWithValue(const S('en')),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ReceivePage())),
    ));
    return container;
  }

  testWidgets('typing a complete code submits once, incomplete input waits', (tester) async {
    final core = FakeCoreState();
    await mount(tester, core);
    await tester.enterText(find.byType(TextField), 'mxt3x-f8sk');
    expect(core.requests, isEmpty);
    await tester.enterText(find.byType(TextField), 'mxt3x-f8sk2');
    await tester.pump();
    expect(core.requests, ['MXT3XF8SK2']);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
  });

  testWidgets('OS link activation starts a receive and consumes the pending code', (tester) async {
    final core = FakeCoreState();
    final container = await mount(tester, core);
    container.read(pendingReceiveProvider.notifier).set('MXT3XF8SK2');
    await tester.pump();
    expect(core.requests, ['MXT3XF8SK2']);
    expect(container.read(pendingReceiveProvider), isNull);
  });

  testWidgets('unavailable service leaves the code available for retry', (tester) async {
    final core = FakeCoreState()..configured = false;
    await mount(tester, core);
    await tester.enterText(find.byType(TextField), 'MXT3XF8SK2');
    await tester.pump();
    expect(core.requests, isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'MXT3XF8SK2');
    expect(find.text(const S('en')('service.unavailable')), findsOneWidget);
  });
}
