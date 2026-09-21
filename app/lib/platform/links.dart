// crosstransfer:// and https://<link_host>/r/<code> link handling.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../state/format.dart';

class LinkHandler {
  LinkHandler._();
  static final LinkHandler instance = LinkHandler._();

  final _links = AppLinks();
  StreamSubscription<Uri>? _sub;

  /// Calls [onCode] with the canonical take-code for every incoming link.
  Future<void> start(void Function(String code) onCode) async {
    void handle(Uri? uri) {
      if (uri == null) return;
      final code = extractTakeCode(uri.toString());
      if (code != null) onCode(code);
    }

    // app_links includes the cold-start URI in this stream. Reading it with
    // getInitialLink as well delivers the same activation twice.
    await _sub?.cancel();
    _sub = _links.uriLinkStream.listen(handle, onError: (Object e) {
      debugPrint('link stream: $e');
    });
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }
}
