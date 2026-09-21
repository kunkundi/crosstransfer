import 'dart:async';

import 'package:crosstransfer/i18n/strings.dart';
import 'package:crosstransfer/platform/mobile.dart';
import 'package:crosstransfer/state/providers.dart';
import 'package:crosstransfer/ui/scan_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String? received;
  Future<void> open(
    WidgetTester tester,
    Future<Object?> Function(MethodCall) handler,
  ) async {
    received = 'pending';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MobilePlatform.channel, handler);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MobilePlatform.channel, null),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sProvider.overrideWithValue(const S('en'))],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  received = await Navigator.of(context).push<String>(
                    MaterialPageRoute(builder: (_) => const ScanPage()),
                  );
                },
                child: const Text('open scanner'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open scanner'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('native QR link returns one normalized take code', (
    tester,
  ) async {
    var scans = 0;
    await open(tester, (call) async {
      expect(call.method, 'ScanCode');
      expect(call.arguments['title'], 'Scan QR code');
      scans++;
      return 'crosstransfer://r/MXT3XF8SK2';
    });
    await tester.pumpAndSettle();
    expect(received, 'MXT3XF8SK2');
    expect(scans, 1);
  });

  testWidgets('invalid QR can be scanned again; cancellation returns no code', (
    tester,
  ) async {
    var scans = 0;
    await open(tester, (_) async => ++scans == 1 ? 'unrelated QR' : null);
    await tester.pumpAndSettle();
    expect(find.text(const S('en')('recv.invalid')), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(received, isNull);
    expect(scans, 2);
  });

  testWidgets('permission failure stays retryable and does not claim a code', (
    tester,
  ) async {
    await open(tester, (_) async => throw PlatformException(code: 'camera'));
    await tester.pumpAndSettle();
    expect(find.text(const S('en')('recv.camera_error')), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(received, 'pending');
  });

  testWidgets(
    'closing the route cancels native capture and ignores late results',
    (tester) async {
      final native = Completer<String?>();
      var cancelled = false;
      await open(tester, (call) async {
        if (call.method == 'CancelScan') {
          cancelled = true;
          return null;
        }
        return native.future;
      });
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(cancelled, isTrue);
      native.complete('MXT3XF8SK2');
      await tester.pumpAndSettle();
      expect(received, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
