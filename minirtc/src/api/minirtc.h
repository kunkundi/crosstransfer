/*
 * MiniRTC — CrossTransfer specialised build.
 * Data-only peer transport: WSS signaling, ICE (libjuice), DTLS-SRTP,
 * reliable (KCP) and unreliable RTP data streams, delay-based bandwidth
 * estimation, WebSocket relay fallback.
 *
 * Copyright (c) 2024-2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef MINIRTC_H_
#define MINIRTC_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(_MSC_VER)
#define MINIRTC_API __declspec(dllexport)
#elif defined(__GNUC__)
#define MINIRTC_API __attribute__((visibility("default")))
#else
#define MINIRTC_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ---- enums ---------------------------------------------------------- */

/** State of the WebSocket signaling connection. */
typedef enum MiniRtcSignalStatus {
  MINIRTC_SIGNAL_CONNECTING = 0,
  MINIRTC_SIGNAL_CONNECTED,     /**< welcome received; peer_id valid */
  MINIRTC_SIGNAL_FAILED,
  MINIRTC_SIGNAL_CLOSED,
  MINIRTC_SIGNAL_RECONNECTING,
  MINIRTC_SIGNAL_TLS_ERROR
} MiniRtcSignalStatus;

/** State of one peer session (created by claim / share pairing). */
typedef enum MiniRtcSessionStatus {
  MINIRTC_SESSION_CONNECTING = 0, /**< session_start received, ICE running */
  MINIRTC_SESSION_CONNECTED,      /**< transport usable (DTLS done if SRTP) */
  MINIRTC_SESSION_DISCONNECTED,   /**< path lost, may recover */
  MINIRTC_SESSION_FAILED,
  MINIRTC_SESSION_CLOSED
} MiniRtcSessionStatus;

/** Share lifecycle events. */
typedef enum MiniRtcShareEvent {
  MINIRTC_SHARE_CREATED = 0, /**< share_id, code valid */
  MINIRTC_SHARE_CLOSED,      /**< detail = reason */
  MINIRTC_SHARE_CLAIMED,     /**< a receiver paired; detail = session_id */
  MINIRTC_SHARE_FAILED       /**< detail = error code */
} MiniRtcShareEvent;

/** Result of a claim request. */
typedef enum MiniRtcClaimResult {
  MINIRTC_CLAIM_OK = 0,           /**< session_start follows */
  MINIRTC_CLAIM_CODE_NOT_FOUND,
  MINIRTC_CLAIM_CODE_EXPIRED,
  MINIRTC_CLAIM_SHARE_BUSY,
  MINIRTC_CLAIM_RATE_LIMITED,
  MINIRTC_CLAIM_ERROR
} MiniRtcClaimResult;

/** Observed transport path. */
typedef enum MiniRtcPath {
  MINIRTC_PATH_UNKNOWN = 0,
  MINIRTC_PATH_P2P,
  MINIRTC_PATH_TURN,
  MINIRTC_PATH_WS_RELAY
} MiniRtcPath;

typedef enum MiniRtcTurnMode {
  MINIRTC_TURN_DISABLED = 0, /**< host + srflx only */
  MINIRTC_TURN_AUTO,         /**< add TURN-UDP relay candidates */
  MINIRTC_TURN_FORCE         /**< relay candidates only */
} MiniRtcTurnMode;

/* ---- structs -------------------------------------------------------- */

typedef struct MiniRtcPeer MiniRtcPeer;

/** Link estimate for one session. */
typedef struct MiniRtcLinkEstimate {
  int64_t bwe_bps;        /**< send-side bandwidth estimate (0 = unknown) */
  int64_t pacing_bps;     /**< current pacer rate */
  int32_t rtt_ms;         /**< smoothed RTT (-1 = unknown) */
  float loss;             /**< fraction lost [0,1] from feedback */
  MiniRtcPath path;
  bool srtp_active;
} MiniRtcLinkEstimate;

/** Periodic traffic statistics for one session (about once per second). */
typedef struct MiniRtcNetStats {
  uint32_t send_bitrate_bps;
  uint32_t recv_bitrate_bps;
  uint64_t sent_packets;
  uint64_t recv_packets;
  uint64_t sent_bytes;
  uint64_t recv_bytes;
  MiniRtcLinkEstimate link;
} MiniRtcNetStats;

/* ---- callbacks (may run on internal threads; copy borrowed data) ---- */

typedef void (*MiniRtcOnSignalStatus)(MiniRtcSignalStatus status,
                                      const char* peer_id, void* user_data);

typedef void (*MiniRtcOnShareEvent)(MiniRtcShareEvent event,
                                    const char* share_id, const char* code,
                                    int64_t expires_at, const char* detail,
                                    void* user_data);

typedef void (*MiniRtcOnClaimResult)(MiniRtcClaimResult result,
                                     const char* session_id,
                                     const char* resume_token,
                                     const char* message, void* user_data);

/**
 * Session status. `role` is "sender" or "receiver". `meta_json` is the
 * share meta (receiver only, on CONNECTING). `path` is valid on CONNECTED.
 */
typedef void (*MiniRtcOnSessionStatus)(MiniRtcSessionStatus status,
                                       const char* session_id,
                                       const char* role,
                                       const char* resume_token,
                                       const char* meta_json,
                                       MiniRtcPath path, const char* reason,
                                       void* user_data);

typedef void (*MiniRtcOnReceiveData)(const uint8_t* data, size_t len,
                                     const char* session_id,
                                     const char* stream, void* user_data);

typedef void (*MiniRtcOnNetStats)(const char* session_id,
                                  const MiniRtcNetStats* stats,
                                  void* user_data);

/** Peer parameters. Strings are copied by MiniRtcCreate. */
typedef struct MiniRtcParams {
  const char* server_host;   /**< signaling host (no scheme) */
  int server_port;
  bool server_tls;           /**< wss:// (true) or ws:// (false) */
  const char* server_path;   /**< default "/ws" */
  const char* log_dir;       /**< default "logs" */

  MiniRtcTurnMode turn_mode;
  bool enable_srtp;          /**< DTLS-SRTP on the data path */
  bool enable_upnp;          /**< try IGD port mapping for host candidates */
  bool enable_ws_relay;      /**< fall back to WebSocket relay when ICE fails */
  bool force_ws_relay;       /**< skip ICE entirely and use the WebSocket relay */
  int ice_timeout_ms;        /**< ICE failure timeout before relay fallback (default 15000) */

  const char* app;           /**< hello.app */
  const char* version;       /**< hello.version */
  const char* platform;      /**< hello.platform */

  MiniRtcOnSignalStatus on_signal_status;
  MiniRtcOnShareEvent on_share_event;
  MiniRtcOnClaimResult on_claim_result;
  MiniRtcOnSessionStatus on_session_status;
  MiniRtcOnReceiveData on_receive_data;
  MiniRtcOnNetStats on_net_stats;
  void* user_data;
} MiniRtcParams;

/* ---- API ------------------------------------------------------------ */

MINIRTC_API const char* MiniRtcVersion(void);

MINIRTC_API MiniRtcPeer* MiniRtcCreate(const MiniRtcParams* params);
MINIRTC_API void MiniRtcDestroy(MiniRtcPeer** peer);

/** Register a data stream. Call before MiniRtcConnect. */
MINIRTC_API int MiniRtcAddDataStream(MiniRtcPeer* peer, const char* name,
                                        bool reliable);
/** KCP send/receive window (packets) for a reliable stream. Default 1024. */
MINIRTC_API int MiniRtcSetReliableWindow(MiniRtcPeer* peer,
                                            const char* stream, int wnd);

/** Open the signaling connection and send hello. Asynchronous. */
MINIRTC_API int MiniRtcConnect(MiniRtcPeer* peer);
/** Close signaling and all sessions. */
MINIRTC_API int MiniRtcDisconnect(MiniRtcPeer* peer);

/** mode: "once" | "open"; ttl_sec <= 0 → server default. meta_json may be NULL. */
MINIRTC_API int MiniRtcCreateShare(MiniRtcPeer* peer, const char* mode,
                                     int ttl_sec, const char* meta_json);
MINIRTC_API int MiniRtcCloseShare(MiniRtcPeer* peer, const char* share_id);

/** Claim a take-code (any accepted form) or resume with a token. */
MINIRTC_API int MiniRtcClaim(MiniRtcPeer* peer, const char* code,
                              const char* resume_token);
MINIRTC_API int MiniRtcLeave(MiniRtcPeer* peer, const char* session_id);

/**
 * Send on a stream. Unreliable: one datagram ≤ 1150 bytes, dropped if the
 * pacer queue is saturated (returns 1). Reliable: queued into KCP; returns
 * 1 when the send window is full (caller should retry later).
 */
MINIRTC_API int MiniRtcSend(MiniRtcPeer* peer, const char* session_id,
                             const char* stream, const void* data,
                             size_t len);

MINIRTC_API int MiniRtcGetLinkEstimate(MiniRtcPeer* peer,
                                          const char* session_id,
                                          MiniRtcLinkEstimate* out);

/** Maximum unreliable payload per MiniRtcSend call. */
MINIRTC_API size_t MiniRtcMaxDatagramSize(void);

#ifdef __cplusplus
}
#endif

#endif /* MINIRTC_H_ */
