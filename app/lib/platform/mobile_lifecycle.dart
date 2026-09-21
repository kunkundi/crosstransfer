import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ffi/core_client.dart';
import '../state/providers.dart';
import 'mobile.dart';

/// One background assertion for all active work, with no automatic renewal
/// after iOS expires it. The UI asks the user to resume paused transfers.
class MobileLifecycle {
  MobileLifecycle(this.onExpired, this.onInboxChanged);
  final void Function() onExpired;
  final Future<void> Function() onInboxChanged;
  bool? _active;
  CoreState? _state;
  CoreStateNotifier? _notifier;

  void start() {
    if (!MobilePlatform.isIOS) return;
    MobilePlatform.channel.setMethodCallHandler((call) async {
      if (call.method == 'InboxChanged') await onInboxChanged();
      if (call.method == 'BackgroundExpired') {
        final state = _state;
        if (state != null) {
          for (final transfer in state.transfers.values) {
            if (transfer.isTerminal || transfer.state == 'paused') continue;
            try {
              _notifier?.pauseTransfer(transfer.transferId);
            } on CoreException catch (e) {
              debugPrint('background pause: $e');
            }
          }
        }
        onExpired();
      }
    });
  }

  static bool hasActiveWork(CoreState state) =>
      state.shares.values.any((s) => s.isActive) ||
      state.receives.values.any((r) => r.isActive && r.state != 'paused') ||
      state.transfers.values.any((t) => !t.isTerminal && t.state != 'paused');

  void update(CoreState state, CoreStateNotifier notifier) {
    _state = state;
    _notifier = notifier;
    final active = hasActiveWork(state);
    if (active == _active) return;
    _active = active;
    unawaited(
      MobilePlatform.setTransferActive(active).catchError((Object e) {
        debugPrint('background task: $e');
      }),
    );
  }

  void dispose() {
    if (!MobilePlatform.isIOS) return;
    MobilePlatform.channel.setMethodCallHandler(null);
    unawaited(
      MobilePlatform.setTransferActive(false).catchError((Object _) {}),
    );
  }
}
