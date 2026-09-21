import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:crosstransfer/ffi/core_client.dart';

Future<void> waitFor(bool Function() predicate, {int seconds = 60}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('Timed out waiting for native transfer');
}

Future<void> transfer(String relay) async {
  final temp = await getTemporaryDirectory();
  final root = await Directory(
    '${temp.path}/ct-native-${DateTime.now().microsecondsSinceEpoch}',
  ).create();
  final source = Directory('${root.path}/source');
  await Directory('${source.path}/子目录/empty').create(recursive: true);
  final payload = List<int>.generate(1024 * 1024 + 37, (i) => i % 251);
  await File('${source.path}/子目录/中文.bin').writeAsBytes(payload);
  await File('${source.path}/zero.bin').writeAsBytes([]);
  final destination = '${root.path}/received';
  CoreClient create(String name) => CoreClient.create({
    'data_dir': '${root.path}/$name',
    'save_dir': destination,
    'server': {'host': '127.0.0.1', 'port': 19090, 'tls': false},
    'turn_mode': 'off',
    'ws_relay': relay,
    'platform': 'android-test',
  });
  final sender = create('sender');
  final receiver = create('receiver');
  final paths = <String>{};
  final events = receiver.events.listen((event) {
    final path = event['path'];
    if (path is String) paths.add(path);
  });
  try {
    expect(CoreClient.version, isNotEmpty);
    await waitFor(
      () =>
          sender.query('all')['signal_connected'] == true &&
          receiver.query('all')['signal_connected'] == true,
    );
    sender.shareCreate([source.path]);
    var code = '';
    await waitFor(() {
      final shares = sender.query('shares')['shares'] as List;
      if (shares.isNotEmpty) code = shares.first['code'] as String;
      return code.isNotEmpty;
    });
    receiver.receiveStart(code, saveDir: destination);
    await waitFor(() {
      final receives = receiver.query('receives')['receives'] as List;
      if (receives.isEmpty) return false;
      if (receives.first['state'] == 'failed') throw StateError('$receives');
      return receives.first['state'] == 'completed';
    });
    expect(await File('$destination/source/子目录/中文.bin').readAsBytes(), payload);
    expect(await File('$destination/source/zero.bin').length(), 0);
    expect(await Directory('$destination/source/子目录/empty').exists(), isTrue);
    expect(paths, contains(relay == 'force' ? 'relay' : 'p2p'));
  } finally {
    await events.cancel();
    receiver.dispose();
    sender.dispose();
    await root.delete(recursive: true);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in ['off', 'force']) {
    testWidgets('native transfer via ${mode == 'force' ? 'relay' : 'P2P'}', (
      tester,
    ) async {
      await tester.runAsync(() => transfer(mode));
    });
  }
}
