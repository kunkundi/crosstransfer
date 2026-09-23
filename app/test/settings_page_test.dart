import 'package:crosstransfer/ffi/core_client.dart';
import 'package:crosstransfer/ffi/ct_bindings.g.dart';
import 'package:crosstransfer/state/models.dart';
import 'package:crosstransfer/state/providers.dart';
import 'package:crosstransfer/ui/settings_page.dart';
import 'package:crosstransfer/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _SettingsCore extends CoreStateNotifier {
  bool fail = false;
  final patches = <Map<String, dynamic>>[];

  @override
  CoreState build() => const CoreState(
    config: CoreConfig({
      'save_dir': '/tmp/received',
      'share': {'mode': 'once', 'ttl_sec': 600},
    }),
  );

  @override
  void updateConfig(Map<String, dynamic> patch) {
    if (fail) throw CoreException(CtStatus.CT_ERR_IO, 'save');
    patches.add(patch);
    state = state.copyWith(config: CoreConfig({...state.config.raw, ...patch}));
  }
}

class _Language extends LanguageNotifier {
  @override
  String build() => 'en';

  @override
  Future<void> set(String lang) async => state = lang;
}

void main() {
  Future<ProviderContainer> mount(
    WidgetTester tester,
    _SettingsCore core,
  ) async {
    tester.view.physicalSize = const Size(360, 382);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        coreStateProvider.overrideWith(() => core),
        languageProvider.overrideWith(_Language.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(
            Brightness.light,
            platform: TargetPlatform.macOS,
          ),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    return container;
  }

  Future<void> choose(WidgetTester tester, String key, String choice) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, choice));
    await tester.pumpAndSettle();
  }

  testWidgets('desktop language and lifetime share save and cancel behavior', (
    tester,
  ) async {
    final core = _SettingsCore();
    final container = await mount(tester, core);
    await choose(tester, 'settings-language', '中文');
    await choose(tester, 'settings-ttl-preset', '30 minutes');
    expect(container.read(languageProvider), 'en');
    expect(core.patches, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('English'), findsOneWidget);
    expect(find.text('10 minutes'), findsOneWidget);
    expect(find.text('Save'), findsNothing);

    await choose(tester, 'settings-language', '中文');
    await choose(tester, 'settings-ttl-preset', '30 minutes');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(container.read(languageProvider), 'zh');
    expect((core.patches.single['share'] as Map)['ttl_sec'], 1800);
    expect(find.text('保存'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'custom lifetime validates before saving and retains valid seconds',
    (tester) async {
      final core = _SettingsCore();
      await mount(tester, core);
      await choose(tester, 'settings-ttl-preset', 'Custom');
      final field = find.byKey(const Key('settings-ttl'));
      await tester.enterText(field, '29');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(core.patches, isEmpty);
      expect(tester.widget<TextField>(field).controller!.text, '29');
      await tester.enterText(field, '45');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((core.patches.single['share'] as Map)['ttl_sec'], 45);
      expect(find.text('Save'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed settings save retains drafts without applying language', (
    tester,
  ) async {
    final core = _SettingsCore()..fail = true;
    final container = await mount(tester, core);
    await choose(tester, 'settings-language', '中文');
    await choose(tester, 'settings-ttl-preset', '1 hour');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(container.read(languageProvider), 'en');
    expect(core.patches, isEmpty);
    expect(find.text('1 hour'), findsOneWidget);
    core.fail = false;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(container.read(languageProvider), 'zh');
    expect((core.patches.single['share'] as Map)['ttl_sec'], 3600);
    expect(tester.takeException(), isNull);
  });
}
