import 'package:crosstransfer/state/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('take-code parsing', () {
    test('normalises spelling variants', () {
      expect(normalizeTakeCode('mxt3x-f8sk2'), 'MXT3XF8SK2');
      expect(normalizeTakeCode('MXT3X F8SK2'), 'MXT3XF8SK2');
      expect(normalizeTakeCode('mxt3x_f8sk2'), 'MXT3XF8SK2');
      // O -> 0, I / L -> 1
      expect(normalizeTakeCode('OXT3X-F8SKI'), '0XT3XF8SK1');
      expect(normalizeTakeCode('lXT3X-F8SK2'), '1XT3XF8SK2');
    });

    test('rejects bad input', () {
      expect(normalizeTakeCode(''), isNull);
      expect(normalizeTakeCode('MXT3X-F8SK'), isNull); // 9 symbols
      expect(normalizeTakeCode('MXT3X-F8SK22'), isNull); // 11 symbols
      expect(normalizeTakeCode('MXT3X-F8SU2'), isNull); // U not in alphabet
      expect(normalizeTakeCode('MXT3X-F8S*2'), isNull);
    });

    test('extracts codes from links', () {
      expect(extractTakeCode('crosstransfer://r/MXT3X-F8SK2'), 'MXT3XF8SK2');
      expect(extractTakeCode('  https://ct.example.com/r/MXT3X-F8SK2?x=1#f '),
          'MXT3XF8SK2');
      expect(extractTakeCode('http://ct.example.com/r/mxt3xf8sk2'), 'MXT3XF8SK2');
      expect(extractTakeCode('https://ct.example.com/other'), isNull);
      expect(extractTakeCode('MXT3X-F8SK2'), 'MXT3XF8SK2');
    });

    test('formats canonical codes', () {
      expect(formatTakeCode('MXT3XF8SK2'), 'MXT3X-F8SK2');
      expect(formatTakeCode('short'), 'short');
    });
  });

  group('formatting', () {
    test('bytes and rates', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1024), '1.0 KiB');
      expect(formatBytes(3000000), '2.9 MiB');
      expect(formatRate(8 * 1024 * 1024), '1.0 MiB/s');
    });

    test('eta and countdown', () {
      expect(formatEta(-1), '--');
      expect(formatEta(59), '59s');
      expect(formatEta(61), '1m 1s');
      expect(formatEta(3700), '1h 1m');
      expect(formatCountdown(0), '0:00');
      expect(formatCountdown(65), '1:05');
    });
  });
}
