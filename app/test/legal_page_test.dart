import 'dart:async';
import 'dart:io';

import 'package:crosstransfer/i18n/strings.dart';
import 'package:crosstransfer/platform/legal.dart';
import 'package:crosstransfer/ui/legal_page.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Picker extends FilePickerPlatform {
  Uint8List? exported;
  final completed = Completer<void>();
  String? fileName;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    this.fileName = fileName;
    expect(mimeType, 'application/gzip');
    exported = bytes;
    completed.complete();
    return Uri.file('/saved/$fileName');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled native licenses load offline with the source notice', () async {
    final entries = await loadNativeLicenses().toList();
    expect(
      entries.length,
      Platform.isLinux ? 14 : (Platform.isAndroid ? 16 : 13),
    );
    final juice = entries.singleWhere(
      (e) => e.packages.single.startsWith('libjuice'),
    );
    final text = juice.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('Mozilla Public License'));
    expect(text, contains(libjuiceSourceName));
    expect(
      text,
      contains('Save it from Settings > About > Third-party notices'),
    );
    for (final source in componentSources.where((s) => s.sourceUrl != null)) {
      final entry = entries.singleWhere(
        (e) => e.packages.single.startsWith(source.title.split(' ').first),
      );
      final notice = entry.paragraphs.map((p) => p.text).join('\n');
      expect(notice, contains(source.sourceUrl!));
      expect(notice, isNot(contains('Save it from')));
    }
  });

  const launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');
  for (final item in componentSources.where((s) => s.sourceUrl != null)) {
    testWidgets('opens the exact upstream source in a browser: ${item.title}', (
      tester,
    ) async {
      MethodCall? launched;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        launcherChannel,
        (call) async {
          launched = call;
          return true;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          launcherChannel,
          null,
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: LegalPage(strings: S('en'), version: '0.1.0'),
        ),
      );
      await tester.tap(find.text('Third-party component source code'));
      await tester.pumpAndSettle();
      final link = find.byKey(ValueKey(item.fileName));
      await tester.scrollUntilVisible(link, 200);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(launched?.method, 'launch');
      expect(launched?.arguments['url'], item.sourceUrl);
      expect(launched?.arguments['useWebView'], isFalse);
      expect(launched?.arguments['useSafariVC'], isFalse);
      expect(find.text('Component source saved'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final throwsError in [false, true]) {
    testWidgets(
      'keeps the source URL available on launch failure ($throwsError)',
      (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          launcherChannel,
          (_) async {
            if (throwsError) throw PlatformException(code: 'unavailable');
            return false;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            launcherChannel,
            null,
          ),
        );
        await tester.pumpWidget(
          const MaterialApp(
            home: LegalPage(strings: S('en'), version: '0.1.0'),
          ),
        );
        await tester.tap(find.text('Third-party component source code'));
        await tester.pumpAndSettle();
        final item = componentSources.firstWhere((s) => s.sourceUrl != null);
        final link = find.byKey(ValueKey(item.fileName));
        await tester.scrollUntilVisible(link, 200);
        await tester.pumpAndSettle();
        await tester.tap(link);
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(SelectableText, item.sourceUrl!),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final item in componentSources.where((s) => s.sourceUrl == null)) {
    testWidgets('legal page exports exact source bytes: ${item.fileName}', (
      tester,
    ) async {
      final previous = FilePickerPlatform.instance;
      final picker = _Picker();
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previous);
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: LegalPage(strings: S('en'), version: '0.1.0'),
        ),
      );
      await tester.tap(find.text('Third-party component source code'));
      await tester.pumpAndSettle();
      final exportButton = find.byKey(ValueKey(item.fileName));
      await tester.scrollUntilVisible(exportButton, 200);
      await tester.pumpAndSettle();
      await tester.tap(exportButton);
      await tester.runAsync(() async {
        await picker.completed.future.timeout(const Duration(seconds: 10));
      });
      await tester.pumpAndSettle();
      final source = await rootBundle.load('assets/legal/${item.fileName}');
      expect(picker.fileName, item.fileName);
      expect(picker.exported, source.buffer.asUint8List());
      expect(find.text('Component source saved'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
