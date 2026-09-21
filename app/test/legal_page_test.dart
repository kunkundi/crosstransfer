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
    expect(entries.length, Platform.isAndroid ? 16 : 13);
    final juice = entries.singleWhere(
      (e) => e.packages.single.startsWith('libjuice'),
    );
    final text = juice.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('Mozilla Public License'));
    expect(text, contains(libjuiceSourceName));
    expect(text, contains('Export it from Settings'));
  });

  for (final item in mplSources) {
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
      final exportButton = find.byKey(ValueKey(item.fileName));
      await tester.scrollUntilVisible(exportButton, 200);
      await tester.tap(exportButton);
      await tester.runAsync(() async {
        await picker.completed.future.timeout(const Duration(seconds: 10));
      });
      await tester.pumpAndSettle();
      final source = await rootBundle.load('assets/legal/${item.fileName}');
      expect(picker.fileName, item.fileName);
      expect(picker.exported, source.buffer.asUint8List());
      expect(find.text('Source saved'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
