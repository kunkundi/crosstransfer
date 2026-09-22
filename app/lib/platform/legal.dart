// Supplemental licenses for components not collected by Flutter's NOTICES.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const libjuiceSourceName = 'libjuice-1.7.2-ct1.tar.gz';
const componentSources =
    <({String title, String fileName, String license, String? sourceUrl})>[
      (
        title: 'libjuice 1.7.2 + ct1',
        fileName: libjuiceSourceName,
        license: 'MPL-2.0',
        sourceUrl: null,
      ),
      (
        title: 'dbus 0.7.15',
        fileName: 'dbus-0.7.15.tar.gz',
        license: 'MPL-2.0',
        sourceUrl: 'https://pub.dev/api/archives/dbus-0.7.15.tar.gz',
      ),
      (
        title: 'gtk 2.2.0 (Dart)',
        fileName: 'gtk-2.2.0.tar.gz',
        license: 'MPL-2.0',
        sourceUrl: 'https://pub.dev/api/archives/gtk-2.2.0.tar.gz',
      ),
    ];

bool _registered = false;

void registerNativeLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(loadNativeLicenses);
}

Stream<LicenseEntry> loadNativeLicenses() async* {
  final manifest = jsonDecode(
    await rootBundle.loadString('assets/legal/native_manifest.json'),
  ) as Map<String, dynamic>;
  for (final item in manifest['components'] as List) {
    final component = item as Map<String, dynamic>;
    final platforms = component['platforms'] as List;
    if (!platforms.contains('all') &&
        !platforms.contains(Platform.operatingSystem)) {
      continue;
    }
    final text = await rootBundle.loadString(
      'assets/legal/${component['asset']}',
    );
    final sourceArchive = component['source_archive'];
    final sourceUrl = component['source_download'];
    final sourceLocation = sourceUrl != null
        ? 'The complete corresponding component source is available at $sourceUrl. '
              'Open it from Settings > About > Third-party notices > '
              'Third-party component source code. '
        : sourceArchive != null
        ? 'The complete corresponding component source is bundled as $sourceArchive. '
              'Save it from Settings > About > Third-party notices > '
              'Third-party component source code. '
        : '';
    final sourceNotice = sourceLocation.isNotEmpty
        ? '\n\n${sourceLocation}CrossTransfer’s proprietary license does not restrict your rights under the component license '
              'to that covered source.'
        : '';
    yield LicenseEntryWithLineBreaks([
      '${component['name']} ${component['version']}',
    ], '${component['source']}\n\n$text$sourceNotice');
  }
}
