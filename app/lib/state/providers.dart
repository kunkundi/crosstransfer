// Riverpod providers: core client, aggregated core state, language.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ffi/core_client.dart';
import '../ffi/ct_bindings.g.dart' show CtStatus;
import '../platform/mobile.dart';
import '../i18n/strings.dart';
import 'app_prefs.dart';
import 'models.dart';

/// Overridden in main() once the data directory is known.
final appPrefsProvider = Provider<AppPrefs>((ref) => throw UnimplementedError());

/// Overridden in main() after the native core is created.
final coreClientProvider =
    Provider<CoreClient>((ref) => throw UnimplementedError());

class LanguageNotifier extends Notifier<String> {
  @override
  String build() => ref.read(appPrefsProvider).language;

  Future<void> set(String lang) async {
    if (!S.supported.contains(lang)) return;
    state = lang;
    await ref.read(appPrefsProvider).set('language', lang);
  }
}

final languageProvider =
    NotifierProvider<LanguageNotifier, String>(LanguageNotifier.new);

final sProvider = Provider<S>((ref) => S(ref.watch(languageProvider)));

/// Which page the shell shows: 0 send, 1 receive, 2 settings.
class NavIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void set(int i) => state = i;
}

final navIndexProvider = NotifierProvider<NavIndexNotifier, int>(NavIndexNotifier.new);

/// A code or link handed over by the URL scheme handler, consumed by the
/// receive page.
class PendingReceiveNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? v) => state = v;
}

final pendingReceiveProvider =
    NotifierProvider<PendingReceiveNotifier, String?>(PendingReceiveNotifier.new);

class CoreError {
  const CoreError(this.seq, this.code, this.message);
  final int seq;
  final String code;
  final String message;
}

class CoreState {
  const CoreState({
    this.signalState = 'closed',
    this.peerId = '',
    this.shares = const {},
    this.receives = const {},
    this.transfers = const {},
    this.config = const CoreConfig({}),
    this.lastError,
  });

  final String signalState;
  final String peerId;
  final Map<String, ShareInfo> shares; // local share id -> info, insertion order
  final Map<String, ReceiveInfo> receives; // transfer id -> info
  final Map<String, TransferInfo> transfers; // transfer id -> info
  final CoreConfig config;
  final CoreError? lastError;

  bool get serverConfigured => config.serverHost.isNotEmpty;

  // Paused senders still own their source files. Receiving never uses Imported.
  bool get hasSendWork => shares.values.any((s) => s.isActive) ||
      transfers.values.any((t) => t.role == 'sender' && !t.isTerminal);

  /// Newest first.
  List<ShareInfo> get shareList {
    final l = shares.values.toList();
    l.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return l;
  }

  List<ReceiveInfo> get receiveList {
    final l = receives.values.toList();
    l.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return l;
  }

  /// Live sender transfers belonging to a share.
  List<TransferInfo> transfersForShare(String shareId) => transfers.values
      .where((t) => t.role == 'sender' && t.shareId == shareId)
      .toList();

  TransferInfo? transferForReceive(String transferId) => transfers[transferId];

  CoreState copyWith({
    String? signalState,
    String? peerId,
    Map<String, ShareInfo>? shares,
    Map<String, ReceiveInfo>? receives,
    Map<String, TransferInfo>? transfers,
    CoreConfig? config,
    CoreError? lastError,
  }) {
    return CoreState(
      signalState: signalState ?? this.signalState,
      peerId: peerId ?? this.peerId,
      shares: shares ?? this.shares,
      receives: receives ?? this.receives,
      transfers: transfers ?? this.transfers,
      config: config ?? this.config,
      lastError: lastError ?? this.lastError,
    );
  }
}

class CoreStateNotifier extends Notifier<CoreState> {
  StreamSubscription<CoreEvent>? _sub;
  int _errorSeq = 0;
  bool _clearingImports = false;

  @override
  CoreState build() {
    final client = ref.watch(coreClientProvider);
    _sub?.cancel();
    _sub = client.events.listen(_onEvent);
    ref.onDispose(() => _sub?.cancel());
    return _initialFromQuery(client);
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  CoreState _initialFromQuery(CoreClient client) {
    final q = client.query('all');
    final shares = <String, ShareInfo>{};
    for (final s in (q['shares'] as List? ?? const [])) {
      if (s is Map<String, dynamic>) {
        final info = ShareInfo.fromJson(s, now: _now);
        shares[info.id] = info;
      }
    }
    final receives = <String, ReceiveInfo>{};
    for (final r in (q['receives'] as List? ?? const [])) {
      if (r is Map<String, dynamic>) {
        final info = ReceiveInfo.fromJson(r, now: _now);
        receives[info.transferId] = info;
      }
    }
    final transfers = <String, TransferInfo>{};
    for (final t in (q['transfers'] as List? ?? const [])) {
      if (t is Map<String, dynamic>) {
        final info = TransferInfo.fromJson(t, now: _now);
        transfers[info.transferId] = info;
      }
    }
    final cfg = q['config'];
    return CoreState(
      signalState: q['signal_connected'] == true ? 'connected' : 'connecting',
      peerId: q['peer_id'] is String ? q['peer_id'] : '',
      shares: shares,
      receives: receives,
      transfers: transfers,
      config: CoreConfig(cfg is Map<String, dynamic> ? cfg : const {}),
    );
  }

  void _onEvent(CoreEvent ev) {
    final type = ev['type'];
    switch (type) {
      case 'signal_state':
        state = state.copyWith(
          signalState: ev['state'] is String ? ev['state'] : state.signalState,
          peerId: ev['peer_id'] is String ? ev['peer_id'] : state.peerId,
        );
      case 'share_state':
        final id = ev['id'];
        if (id is! String || id.isEmpty) return;
        final next = Map<String, ShareInfo>.from(state.shares);
        next[id] = ShareInfo.fromJson(ev, previous: state.shares[id], now: _now);
        state = state.copyWith(shares: next);
      case 'receive_state':
        final id = ev['transfer_id'];
        if (id is! String || id.isEmpty) return;
        final next = Map<String, ReceiveInfo>.from(state.receives);
        next[id] = ReceiveInfo.fromJson(ev, previous: state.receives[id], now: _now);
        state = state.copyWith(receives: next);
      case 'transfer_state':
      case 'transfer_progress':
        final id = ev['transfer_id'];
        if (id is! String || id.isEmpty) return;
        final next = Map<String, TransferInfo>.from(state.transfers);
        next[id] = TransferInfo.fromJson(ev, now: _now);
        state = state.copyWith(transfers: next);
      case 'config':
        final cfg = ev['config'];
        if (cfg is Map<String, dynamic>) {
          state = state.copyWith(config: CoreConfig(cfg));
        }
      case 'error':
        state = state.copyWith(
          lastError: CoreError(
            ++_errorSeq,
            ev['code'] is String ? ev['code'] : '',
            ev['message'] is String ? ev['message'] : '',
          ),
        );
    }
  }

  CoreClient get _client => ref.read(coreClientProvider);

  // ---- actions ------------------------------------------------------------

  String createShare(List<String> paths, {String? mode, int? ttlSec}) {
    if (_clearingImports) throw CoreException(CtStatus.CT_ERR_STATE, 'Import cleanup in progress');
    final id = _client.shareCreate(paths, mode: mode, ttlSec: ttlSec);
    final next = Map<String, ShareInfo>.from(state.shares);
    final existing = next[id];
    next[id] = (existing ??
            ShareInfo.fromJson({'id': id, 'state': 'creating'}, now: _now))
        .withPaths(paths);
    state = state.copyWith(shares: next);
    return id;
  }

  void closeShare(String id) => _client.shareClose(id);

  /// Drops a finished share from the list (local only).
  void removeShare(String id) {
    final s = state.shares[id];
    if (s == null) return;
    if (s.isActive) _client.shareClose(id);
    final next = Map<String, ShareInfo>.from(state.shares)..remove(id);
    state = state.copyWith(shares: next);
  }

  String startReceive(String codeOrLink, {String? saveDir}) {
    final id = _client.receiveStart(codeOrLink, saveDir: saveDir);
    if (!state.receives.containsKey(id)) {
      final next = Map<String, ReceiveInfo>.from(state.receives);
      next[id] = ReceiveInfo.fromJson(
          {'transfer_id': id, 'state': 'claiming', 'save_dir': saveDir ?? ''},
          now: _now);
      state = state.copyWith(receives: next);
    }
    return id;
  }

  void resumeReceive(String transferId) => _client.receiveResume(transferId);
  void pauseTransfer(String transferId) => _client.transferPause(transferId);
  void resumeTransfer(String transferId) {
    if (_clearingImports) throw CoreException(CtStatus.CT_ERR_STATE, 'Import cleanup in progress');
    _client.transferResume(transferId);
  }

  Future<Map<String, dynamic>> clearImports(List<String> ids) async {
    if (_clearingImports || state.hasSendWork) {
      throw CoreException(CtStatus.CT_ERR_STATE, 'Finish or close sending before cleaning imports');
    }
    _clearingImports = true;
    try {
      // Query is a synchronous core-loop barrier: a dismissed share's queued
      // close and sender shutdown must finish before any source can be removed.
      if (_initialFromQuery(_client).hasSendWork) {
        throw CoreException(CtStatus.CT_ERR_STATE, 'Sending is still active');
      }
      return await MobilePlatform.clearImports(ids);
    } finally { _clearingImports = false; }
  }
  void cancelTransfer(String transferId) => _client.transferCancel(transferId);

  /// Drops a receive from the list; cancels it in the core first so its
  /// resume record is cleared too.
  void removeReceive(String transferId) {
    final r = state.receives[transferId];
    if (r == null) return;
    if (!r.isTerminal) _client.transferCancel(transferId);
    final receives = Map<String, ReceiveInfo>.from(state.receives)
      ..remove(transferId);
    final transfers = Map<String, TransferInfo>.from(state.transfers)
      ..remove(transferId);
    state = state.copyWith(receives: receives, transfers: transfers);
  }

  void updateConfig(Map<String, dynamic> patch) => _client.updateConfig(patch);
}

final coreStateProvider =
    NotifierProvider<CoreStateNotifier, CoreState>(CoreStateNotifier.new);
