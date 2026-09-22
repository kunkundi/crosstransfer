import 'package:crosstransfer/i18n/strings.dart';
import 'package:crosstransfer/platform/desktop_basket.dart';
import 'package:crosstransfer/state/models.dart';
import 'package:crosstransfer/state/providers.dart';
import 'package:crosstransfer/ui/receive_page.dart';
import 'package:crosstransfer/ui/send_page.dart';
import 'package:crosstransfer/ui/settings_page.dart';
import 'package:crosstransfer/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCore extends CoreStateNotifier {
  @override
  CoreState build() => CoreState(
    config: CoreConfig({
      'server': {'host': 'localhost'},
      'save_dir': '/Documents/Received',
    }),
  );
}

class _FakeLanguage extends LanguageNotifier {
  @override
  String build() => 'en';
}

void main() {
  for (final language in S.supported) {
    for (final entry in {
      'send': const SendPage(),
      'receive': const ReceivePage(),
      'settings': const SettingsPage(),
    }.entries) {
      testWidgets('${entry.key} fits the fixed desktop window in $language', (
        tester,
      ) async {
        tester.view.physicalSize = DesktopBasket.mainSize;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              coreStateProvider.overrideWith(_FakeCore.new),
              languageProvider.overrideWith(_FakeLanguage.new),
              sProvider.overrideWithValue(S(language)),
            ],
            child: MaterialApp(
              theme: buildAppTheme(Brightness.light),
              home: Scaffold(
                body: Row(
                  children: [
                    const SizedBox(width: 160),
                    const VerticalDivider(width: 1),
                    Expanded(child: entry.value),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final layoutError = tester.takeException();
        expect(
          layoutError,
          isNull,
          reason: layoutError is FlutterError ? layoutError.toStringDeep() : null,
        );

        if (entry.key == 'settings') {
          await tester.drag(find.byType(ListView), const Offset(0, -500));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
