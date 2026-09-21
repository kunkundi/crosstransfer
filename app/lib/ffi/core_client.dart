// CoreClient: thin Dart wrapper over the crosstransfer_native C API.
//
// All Ct* calls are non-blocking; state arrives on [events] as decoded JSON
// maps. The native callback is a NativeCallable.listener, so events are
// delivered on the main isolate without blocking the core event-loop thread.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'ct_bindings.g.dart';
import 'native_library.dart';

class CoreException implements Exception {
  CoreException(this.status, this.what);
  final int status;
  final String what;

  @override
  String toString() => 'CoreException($what: $status)';
}

typedef CoreEvent = Map<String, dynamic>;

class CoreClient {
  CoreClient._(this._b, this._core) {
    _callable = NativeCallable<
        Void Function(Pointer<Char>, Pointer<Void>)>.listener(_onNativeEvent);
    _b.CtSetEventCallbackOwned(_core, _callable!.nativeFunction, nullptr);
  }

  final CtBindings _b;
  Pointer<CtCore> _core;
  NativeCallable<Void Function(Pointer<Char>, Pointer<Void>)>? _callable;
  final _events = StreamController<CoreEvent>.broadcast();

  Stream<CoreEvent> get events => _events.stream;
  bool get isOpen => _core != nullptr;

  static String? _versionCache;

  /// Opens the library and creates a core with [config] (see ct_api.h).
  static CoreClient create(Map<String, dynamic> config) {
    final b = CtBindings(NativeLibrary.open());
    final cfg = jsonEncode(config).toNativeUtf8();
    try {
      final core = b.CtCreate(cfg.cast());
      if (core == nullptr) {
        throw CoreException(CtStatus.CT_ERR_IO, 'CtCreate');
      }
      _versionCache ??= b.CtVersion().cast<Utf8>().toDartString();
      return CoreClient._(b, core);
    } finally {
      malloc.free(cfg);
    }
  }

  static String get version => _versionCache ?? '';

  void _onNativeEvent(Pointer<Char> json, Pointer<Void> _) {
    try {
      final text = json.cast<Utf8>().toDartString();
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> && !_events.isClosed) {
        _events.add(decoded);
      }
    } finally {
      _b.CtFreeString(json);
    }
  }

  void _check(int rc, String what) {
    if (rc != CtStatus.CT_OK) throw CoreException(rc, what);
  }

  T _withUtf8<T>(String s, T Function(Pointer<Char>) fn) {
    final p = s.toNativeUtf8();
    try {
      return fn(p.cast());
    } finally {
      malloc.free(p);
    }
  }

  /// Runs [fn] with an out-parameter slot and returns the malloc'd string it
  /// filled (or null), releasing the native copy.
  String? _withOutString(int Function(Pointer<Pointer<Char>>) fn, String what) {
    final slot = malloc<Pointer<Char>>();
    slot.value = nullptr;
    try {
      final rc = fn(slot);
      String? out;
      if (slot.value != nullptr) {
        out = slot.value.cast<Utf8>().toDartString();
        _b.CtFreeString(slot.value);
      }
      _check(rc, what);
      return out;
    } finally {
      malloc.free(slot);
    }
  }

  void updateConfig(Map<String, dynamic> patch) {
    _withUtf8(jsonEncode(patch),
        (p) => _check(_b.CtUpdateConfig(_core, p), 'CtUpdateConfig'));
  }

  /// Returns the local share id.
  String shareCreate(List<String> paths, {String? mode, int? ttlSec}) {
    final options = <String, dynamic>{};
    if (mode != null) options['mode'] = mode;
    if (ttlSec != null && ttlSec > 0) options['ttl_sec'] = ttlSec;
    return _withUtf8(jsonEncode(paths), (pPaths) {
      return _withUtf8(jsonEncode(options), (pOpt) {
        return _withOutString(
            (slot) => _b.CtShareCreate(_core, pPaths, pOpt, slot),
            'CtShareCreate')!;
      });
    });
  }

  void shareClose(String shareId) {
    _withUtf8(shareId, (p) => _check(_b.CtShareClose(_core, p), 'CtShareClose'));
  }

  /// Returns the transfer id.
  String receiveStart(String codeOrLink, {String? saveDir}) {
    return _withUtf8(codeOrLink, (pCode) {
      int call(Pointer<Char> pDir, Pointer<Pointer<Char>> slot) =>
          _b.CtReceiveStart(_core, pCode, pDir, slot);
      if (saveDir == null || saveDir.isEmpty) {
        return _withOutString((slot) => call(nullptr, slot), 'CtReceiveStart')!;
      }
      return _withUtf8(saveDir, (pDir) {
        return _withOutString((slot) => call(pDir, slot), 'CtReceiveStart')!;
      });
    });
  }

  void receiveResume(String transferId) => _withUtf8(
      transferId, (p) => _check(_b.CtReceiveResume(_core, p), 'CtReceiveResume'));

  void transferPause(String transferId) => _withUtf8(
      transferId, (p) => _check(_b.CtTransferPause(_core, p), 'CtTransferPause'));

  void transferResume(String transferId) => _withUtf8(transferId,
      (p) => _check(_b.CtTransferResume(_core, p), 'CtTransferResume'));

  void transferCancel(String transferId) => _withUtf8(transferId,
      (p) => _check(_b.CtTransferCancel(_core, p), 'CtTransferCancel'));

  /// what: shares | receives | transfers | config | all
  Map<String, dynamic> query(String what) {
    return _withUtf8(jsonEncode({'what': what}), (p) {
      final res = _b.CtQuery(_core, p);
      if (res == nullptr) return <String, dynamic>{};
      try {
        final decoded = jsonDecode(res.cast<Utf8>().toDartString());
        return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      } finally {
        _b.CtFreeString(res);
      }
    });
  }

  /// Detaches the callback and destroys the core. Safe to call once.
  void dispose() {
    if (_core == nullptr) return;
    _b.CtSetEventCallbackOwned(_core, nullptr, nullptr);
    _b.CtDestroy(_core);
    _core = nullptr;
    _callable?.close();
    _callable = null;
    _events.close();
  }
}
