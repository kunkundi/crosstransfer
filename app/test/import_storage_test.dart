import 'dart:async';

import 'package:crosstransfer/ffi/core_client.dart';
import 'package:crosstransfer/i18n/strings.dart';
import 'package:crosstransfer/platform/mobile.dart';
import 'package:crosstransfer/state/models.dart';
import 'package:crosstransfer/state/providers.dart';
import 'package:crosstransfer/ui/import_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class StorageCore implements CoreClient {
  Map<String, dynamic> snapshot = {'shares': [], 'transfers': []};
  @override
  Stream<CoreEvent> get events => const Stream.empty();
  @override
  Map<String, dynamic> query(String what) => snapshot;
  @override
  String shareCreate(List<String> paths, {String? mode, int? ttlSec}) =>
      'share';
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = '1ad0a07e-205a-4b38-8647-5aa7bb8d93f1';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(MobilePlatform.channel, null),
  );

  test('cleanup excludes active and paused senders, but not receivers', () {
    for (final state in ['sending', 'paused', 'connecting']) {
      expect(
        CoreState(
          transfers: {
            't': TransferInfo.fromJson({'role': 'sender', 'state': state}),
          },
        ).hasSendWork,
        isTrue,
      );
    }
    expect(
      CoreState(
        transfers: {
          't': TransferInfo.fromJson({
            'role': 'receiver',
            'state': 'transferring',
          }),
        },
      ).hasSendWork,
      isFalse,
    );
    expect(
      CoreState(
        shares: {
          's': ShareInfo.fromJson({'state': 'ready'}),
        },
      ).hasSendWork,
      isTrue,
    );
  });

  test(
    'cleanup uses a fresh core barrier and locks new sends until completion',
    () async {
      final client = StorageCore();
      final container = ProviderContainer(
        overrides: [coreClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(coreStateProvider.notifier);
      var calls = 0;
      final native = Completer<Map<String, dynamic>>();
      messenger.setMockMethodCallHandler(MobilePlatform.channel, (call) async {
        expect(call.method, 'ClearImports');
        expect(call.arguments, [id]);
        calls++;
        return native.future;
      });
      // UI still looks idle; the authoritative snapshot already has a sender.
      client.snapshot = {
        'shares': [
          {'id': 's', 'state': 'ready'},
        ],
        'transfers': [],
      };
      await expectLater(
        notifier.clearImports([id]),
        throwsA(isA<CoreException>()),
      );
      expect(calls, 0);
      client.snapshot = {'shares': [], 'transfers': []};
      final clearing = notifier.clearImports([id]);
      expect(
        () => notifier.createShare(['/tmp/a']),
        throwsA(isA<CoreException>()),
      );
      expect(() => notifier.resumeTransfer('t'), throwsA(isA<CoreException>()));
      native.complete({'bytes': 0, 'clearable_bytes': 0, 'ids': []});
      await clearing;
      expect(calls, 1);
      expect(notifier.createShare(['/tmp/a']), 'share');
    },
  );

  testWidgets(
    'storage preview requires confirmation and only clears previewed IDs',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = StorageCore();
      var cleared = 0;
      messenger.setMockMethodCallHandler(MobilePlatform.channel, (call) async {
        if (call.method == 'ClearImports') {
          expect(call.arguments, [id]);
          cleared++;
          return {'bytes': 1024, 'clearable_bytes': 0, 'ids': []};
        }
        return {
          'bytes': 5120,
          'clearable_bytes': 4096,
          'ids': [id],
        };
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coreClientProvider.overrideWithValue(client),
            sProvider.overrideWithValue(const S('en')),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: ImportStorage())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('5.0 KiB'), findsOneWidget);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(cleared, 0);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(cleared, 1);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('1.0 KiB'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
    },
  );
}
