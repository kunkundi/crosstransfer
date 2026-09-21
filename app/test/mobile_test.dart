import 'package:crosstransfer/i18n/strings.dart';
import 'package:crosstransfer/platform/mobile_lifecycle.dart';
import 'package:crosstransfer/state/models.dart';
import 'package:crosstransfer/state/providers.dart';
import 'package:crosstransfer/ui/receive_page.dart';
import 'package:crosstransfer/ui/send_page.dart';
import 'package:crosstransfer/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class MobileFakeCore extends CoreStateNotifier {
  @override
  CoreState build() => CoreState(config: CoreConfig({
    'server': {'host': 'localhost'}, 'save_dir': '/Documents/Received',
  }));
}

class FakeLanguage extends LanguageNotifier {
  @override
  String build() => 'en';
}

void main() {
  test('background assertion tracks waiting shares and active receives, not terminal or paused work', () {
    expect(MobileLifecycle.hasActiveWork(const CoreState()), isFalse);
    for (final state in ['ready', 'claimed', 'transferring']) {
      expect(MobileLifecycle.hasActiveWork(CoreState(shares: {
        's': ShareInfo.fromJson({'id': 's', 'state': state}),
      })), isTrue);
    }
    for (final state in ['claiming', 'connecting', 'waiting_offer', 'transferring', 'verifying', 'completed', 'failed', 'paused', 'interrupted']) {
      final active = ['claiming', 'connecting', 'waiting_offer', 'transferring', 'verifying'].contains(state);
      expect(MobileLifecycle.hasActiveWork(CoreState(receives: {
        'r': ReceiveInfo.fromJson({'transfer_id': 'r', 'state': state}),
      })), active, reason: state);
    }
  });

  for (final entry in {'send': const SendPage(), 'receive': const ReceivePage(), 'settings': const SettingsPage()}.entries) {
    testWidgets('${entry.key} fits a 375px phone viewport', (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProviderScope(overrides: [
        coreStateProvider.overrideWith(MobileFakeCore.new),
        languageProvider.overrideWith(FakeLanguage.new),
        sProvider.overrideWithValue(const S('en')),
      ], child: MaterialApp(home: Scaffold(body: entry.value))));
      await tester.pump();
      expect(tester.takeException(), isNull);
      if (entry.key == 'settings') {
        await tester.drag(find.byType(ListView), const Offset(0, -600));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    });
  }
}
