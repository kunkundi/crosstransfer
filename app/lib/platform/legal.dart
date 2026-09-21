// Supplemental licenses for components not collected by Flutter's NOTICES.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const libjuiceSourceName = 'libjuice-1.7.2-ct1.tar.gz';
const mplSources = <({String title, String fileName})>[
  (title: 'libjuice 1.7.2 + ct1', fileName: libjuiceSourceName),
  (title: 'dbus 0.7.15', fileName: 'dbus-0.7.15.tar.gz'),
  (title: 'gtk 2.2.0 (Dart)', fileName: 'gtk-2.2.0.tar.gz'),
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
    final sourceNotice = sourceArchive != null
        ? '\n\nThe complete corresponding MPL-2.0 source is bundled as $sourceArchive. '
              'Export it from Settings > Open-source licenses > Source code. '
              'CrossTransfer’s proprietary license does not restrict your MPL rights '
              'to that covered source.'
        : '';
    yield LicenseEntryWithLineBreaks([
      '${component['name']} ${component['version']}',
    ], '${component['source']}\n\n$text$sourceNotice');
  }
}
