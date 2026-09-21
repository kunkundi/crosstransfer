// Immutable views over core event JSON.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

int _int(dynamic v, [int d = 0]) => v is int ? v : (v is num ? v.toInt() : d);
String _str(dynamic v, [String d = '']) => v is String ? v : d;
bool _bool(dynamic v, [bool d = false]) => v is bool ? v : d;

class ShareInfo {
  const ShareInfo({
    required this.id,
    required this.shareId,
    required this.state,
    required this.mode,
    required this.code,
    required this.link,
    required this.schemeLink,
    required this.expiresAt,
    required this.files,
    required this.bytes,
    required this.receivers,
    required this.completed,
    required this.error,
    required this.createdAt,
    this.paths = const [],
  });

  factory ShareInfo.fromJson(Map<String, dynamic> j,
      {ShareInfo? previous, int? now}) {
    return ShareInfo(
      id: _str(j['id']),
      shareId: _str(j['share_id']),
      state: _str(j['state']),
      mode: _str(j['mode']),
      code: _str(j['code']),
      link: _str(j['link']),
      schemeLink: _str(j['scheme_link']),
      expiresAt: _int(j['expires_at']),
      files: _int(j['files']),
      bytes: _int(j['bytes']),
      receivers: _int(j['receivers']),
      completed: _int(j['completed']),
      error: _str(j['error']),
      createdAt: previous?.createdAt ?? now ?? 0,
      paths: previous?.paths ?? const [],
    );
  }

  final String id;
  final String shareId;
  final String state; // creating ready claimed transferring completed closed failed
  final String mode; // once | open
  final String code;
  final String link;
  final String schemeLink;
  final int expiresAt; // unix seconds, 0 = unknown
  final int files;
  final int bytes;
  final int receivers;
  final int completed;
  final String error;
  final int createdAt; // local ms
  final List<String> paths; // what the user shared (local only)

  bool get isActive =>
      state == 'creating' ||
      state == 'ready' ||
      state == 'claimed' ||
      state == 'transferring';
  bool get isTerminal => !isActive;

  ShareInfo withPaths(List<String> p) => ShareInfo(
        id: id,
        shareId: shareId,
        state: state,
        mode: mode,
        code: code,
        link: link,
        schemeLink: schemeLink,
        expiresAt: expiresAt,
        files: files,
        bytes: bytes,
        receivers: receivers,
        completed: completed,
        error: error,
        createdAt: createdAt,
        paths: p,
      );
}

class ReceiveInfo {
  const ReceiveInfo({
    required this.transferId,
    required this.code,
    required this.state,
    required this.saveDir,
    required this.sessionId,
    required this.resumable,
    required this.errorCode,
    required this.errorMessage,
    required this.meta,
    required this.createdAt,
  });

  factory ReceiveInfo.fromJson(Map<String, dynamic> j,
      {ReceiveInfo? previous, int? now}) {
    final meta = j['meta'];
    return ReceiveInfo(
      transferId: _str(j['transfer_id']),
      code: _str(j['code']),
      state: _str(j['state']),
      saveDir: _str(j['save_dir']),
      sessionId: _str(j['session_id'], previous?.sessionId ?? ''),
      resumable: _bool(j['resumable']),
      errorCode: _str(j['error_code']),
      errorMessage: _str(j['error_message']),
      meta: meta is Map<String, dynamic> ? meta : (previous?.meta ?? const {}),
      createdAt: _int(j['created_at'], previous?.createdAt ?? now ?? 0),
    );
  }

  final String transferId;
  final String code;
  // claiming connecting waiting_offer transferring verifying completed failed
  // cancelled interrupted paused
  final String state;
  final String saveDir;
  final String sessionId;
  final bool resumable;
  final String errorCode;
  final String errorMessage;
  final Map<String, dynamic> meta; // files, bytes, name, roots (from sender)
  final int createdAt;

  bool get isTerminal =>
      state == 'completed' || state == 'failed' || state == 'cancelled';
  bool get isInterrupted => state == 'interrupted';
  bool get isActive => !isTerminal && !isInterrupted;

  String get metaName => _str(meta['name']);
  int get metaFiles => _int(meta['files']);
  int get metaBytes => _int(meta['bytes']);
  int get metaRoots => _int(meta['roots']);
}

class TransferInfo {
  const TransferInfo({
    required this.transferId,
    required this.sessionId,
    required this.shareId,
    required this.role,
    required this.state,
    required this.errorCode,
    required this.errorMessage,
    required this.path,
    required this.bytesTotal,
    required this.bytesDone,
    required this.filesTotal,
    required this.filesDone,
    required this.rateBps,
    required this.lossPermille,
    required this.currentFile,
    required this.etaSec,
    required this.updatedAt,
  });

  factory TransferInfo.fromJson(Map<String, dynamic> j, {int? now}) {
    return TransferInfo(
      transferId: _str(j['transfer_id']),
      sessionId: _str(j['session_id']),
      shareId: _str(j['share_id']),
      role: _str(j['role']),
      state: _str(j['state']),
      errorCode: _str(j['error_code']),
      errorMessage: _str(j['error_message']),
      path: _str(j['path']),
      bytesTotal: _int(j['bytes_total']),
      bytesDone: _int(j['bytes_done']),
      filesTotal: _int(j['files_total']),
      filesDone: _int(j['files_done']),
      rateBps: _int(j['rate_bps']),
      lossPermille: _int(j['loss_permille']),
      currentFile: _int(j['current_file'], -1),
      etaSec: _int(j['eta_sec'], -1),
      updatedAt: now ?? 0,
    );
  }

  final String transferId;
  final String sessionId;
  final String shareId; // sender side: local share id
  final String role; // sender | receiver
  final String state;
  final String errorCode;
  final String errorMessage;
  final String path; // p2p | turn | relay | unknown
  final int bytesTotal;
  final int bytesDone;
  final int filesTotal;
  final int filesDone;
  final int rateBps;
  final int lossPermille;
  final int currentFile;
  final int etaSec;
  final int updatedAt;

  double get fraction =>
      bytesTotal > 0 ? (bytesDone / bytesTotal).clamp(0.0, 1.0) : 0.0;
  bool get isTerminal =>
      state == 'completed' || state == 'failed' || state == 'cancelled';
}

class CoreConfig {
  const CoreConfig(this.raw);
  final Map<String, dynamic> raw;

  Map<String, dynamic> get _server =>
      raw['server'] is Map<String, dynamic> ? raw['server'] : const {};
  Map<String, dynamic> get _share =>
      raw['share'] is Map<String, dynamic> ? raw['share'] : const {};

  String get dataDir => _str(raw['data_dir']);
  String get logDir => _str(raw['log_dir']);
  String get logLevel => _str(raw['log_level'], 'info');
  String get serverHost => _str(_server['host']);
  int get serverPort => _int(_server['port'], 443);
  bool get serverTls => _bool(_server['tls'], true);
  String get serverPath => _str(_server['path'], '/ws');
  String get linkHost => _str(raw['link_host']);
  String get turnMode => _str(raw['turn_mode'], 'auto');
  String get wsRelay => _str(raw['ws_relay'], 'auto');
  bool get enableSrtp => _bool(raw['enable_srtp'], true);
  bool get enableUpnp => _bool(raw['enable_upnp'], false);
  String get saveDir => _str(raw['save_dir']);
  String get shareMode => _str(_share['mode'], 'once');
  int get shareTtlSec => _int(_share['ttl_sec'], 600);
  String get appVersion => _str(raw['app_version']);
}
