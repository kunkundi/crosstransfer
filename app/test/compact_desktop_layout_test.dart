import 'package:crosstransfer/i18n/strings.dart';
import 'package:crosstransfer/platform/desktop_window.dart';
import 'package:crosstransfer/state/models.dart';
import 'package:crosstransfer/state/providers.dart';
import 'package:crosstransfer/ui/receive_page.dart';
import 'package:crosstransfer/ui/desktop_layout.dart';
import 'package:crosstransfer/ui/send_page.dart';
import 'package:crosstransfer/ui/desktop_send_page.dart';
import 'package:crosstransfer/ui/settings_page.dart';
import 'package:crosstransfer/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCore extends CoreStateNotifier {
  _FakeCore({this.populated = false});
  final bool populated;
  @override
  CoreState build() => CoreState(
    config: CoreConfig({
      'service_available': true,
      'save_dir': '/Documents/Received',
    }),
    shares: !populated
        ? {}
        : {
            for (final state in ['ready', 'failed'])
              state: ShareInfo.fromJson({
                'id': state,
                'state': state,
                'code': 'MXT3X-F8SK2',
                'link': 'crosstransfer://r/MXT3XF8SK2',
                'mode': 'once',
                'files': 12,
                'bytes': 104857600,
                'error': state == 'failed' ? 'signal' : '',
              }).withPaths(['/Documents/A long filename 文件分享与设计素材.zip']),
          },
    receives: !populated
        ? {}
        : {
            for (final state in ['transferring', 'failed'])
              state: ReceiveInfo.fromJson({
                'transfer_id': state,
                'state': state,
                'code': 'MXT3X-F8SK2',
                'save_dir': '/Documents/Received',
                'meta': {
                  'name': 'Design assets 设计素材.zip',
                  'files': 12,
                  'bytes': 104857600,
                },
                'error_code': state == 'failed' ? 'code_expired' : '',
              }),
          },
    transfers: !populated
        ? {}
        : {
            'transferring': TransferInfo.fromJson({
              'transfer_id': 'transferring',
              'state': 'transferring',
              'bytes_total': 104857600,
              'bytes_done': 52428800,
              'files_total': 12,
              'files_done': 6,
              'rate_bps': 1048576,
              'eta_sec': 50,
              'path': 'p2p',
            }),
          },
  );
}

class _FakeLanguage extends LanguageNotifier {
  @override
  String build() => 'en';
}

void main() {
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final brightness in Brightness.values) {
      for (final language in S.supported) {
        for (final scale in [1.0, 1.5]) {
          for (final entry in {
            'send': const DesktopSendPage(),
            'history': const SendPage(historyOnly: true),
            'receive': const ReceivePage(),
            'settings': const SettingsPage(),
          }.entries) {
            for (final populated in [
              false,
              if (platform == TargetPlatform.macOS && entry.key != 'settings')
                true,
            ]) {
              testWidgets(
                '${entry.key} fits ${platform.name} ${brightness.name} $language at $scale (populated: $populated)',
                (tester) async {
                  tester.view.physicalSize = DesktopWindow.size;
                  tester.view.devicePixelRatio = 1;
                  addTearDown(tester.view.resetPhysicalSize);
                  addTearDown(tester.view.resetDevicePixelRatio);
                  await tester.pumpWidget(
                    ProviderScope(
                      overrides: [
                        coreStateProvider.overrideWith(
                          () => _FakeCore(
                            populated: populated || entry.key == 'history',
                          ),
                        ),
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
                        home: Scaffold(
                          body: DesktopLayout(
                            strings: S(language),
                            selectedIndex: 0,
                            onSelected: (_) {},
                            child: entry.value,
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
                    reason: layoutError is FlutterError
                        ? layoutError.toStringDeep()
                        : null,
                  );
                  if (entry.key == 'settings' ||
                      entry.key == 'history' ||
                      (entry.key == 'receive' && populated)) {
                    await tester.drag(
                      find.byType(ListView),
                      const Offset(0, -500),
                    );
                    await tester.pump();
                    expect(tester.takeException(), isNull);
                  }
                  await tester.pumpWidget(const SizedBox());
                },
              );
            }
          }
        }
      }
    }
  }
}
