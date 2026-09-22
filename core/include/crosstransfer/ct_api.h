/*
 * CrossTransfer core — public C API.
 *
 * Single header consumed by ct_cli and by Dart FFI (ffigen). All functions are
 * non-blocking; results and state changes arrive as UTF-8 JSON events on the
 * callback registered with CtSetEventCallback. The callback runs on the core
 * event-loop thread; copy the JSON and return promptly.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CROSSTRANSFER_CT_API_H_
#define CROSSTRANSFER_CT_API_H_

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(CT_BUILDING_SHARED)
#define CT_API __declspec(dllexport)
#else
#define CT_API
#endif
#elif defined(__GNUC__)
#define CT_API __attribute__((visibility("default")))
#else
#define CT_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CtCore CtCore;

/** Event sink. `json_utf8` is valid only for the duration of the call. */
typedef void (*CtEventCallback)(const char* json_utf8, void* user_data);

/** Return codes for Ct* calls. Asynchronous failures arrive as events. */
typedef enum CtStatus {
  CT_OK = 0,
  CT_ERR_INVALID_ARG = -1, /**< NULL pointer, malformed JSON, bad code */
  CT_ERR_STATE = -2,       /**< call not valid in the current state */
  CT_ERR_NOT_FOUND = -3,   /**< unknown share / transfer id */
  CT_ERR_IO = -4,          /**< data dir / file access failure */
  CT_ERR_INTERNAL = -5
} CtStatus;

/**
 * Create a core instance.
 *
 * config_json (all keys optional unless noted; service keys are developer-only):
 * {
 *   "data_dir": "...",          // required: config.json, transfers.json
 *   "log_dir": "...",           // default <data_dir>/logs
 *   "log_level": "info",        // trace|debug|info|warn|error
 *   "server": {"host": "...", "port": 443, "tls": true, "path": "/ws"},
 *   "link_host": "example.com", // host used in https://<link_host>/r/<code>
 *   "turn_mode": "auto",        // auto|force|off
 *   "ws_relay": "auto",         // auto|force|off
 *   "enable_srtp": true,
 *   "enable_upnp": false,
 *   "save_dir": "...",          // default receive directory
 *   "share": {"mode": "once", "ttl_sec": 600},
 *   "app_version": "0.1.0", "platform": "macos"
 * }
 * Preferences persist to <data_dir>/config.json. Commercial builds ignore service
 * overrides and omit them from saved/query config; service_available is read-only.
 */
CT_API CtCore* CtCreate(const char* config_json);
CT_API void CtDestroy(CtCore* core);

CT_API void CtSetEventCallback(CtCore* core, CtEventCallback cb,
                               void* user_data);

/**
 * Same as CtSetEventCallback, but each event arrives as a malloc'd copy that
 * outlives the call; the callback must release it with CtFreeString. Needed by
 * asynchronous listeners (Dart NativeCallable.listener). Exported only by the
 * crosstransfer_native FFI library.
 */
CT_API void CtSetEventCallbackOwned(CtCore* core, CtEventCallback cb,
                                    void* user_data);

/** Merge preferences; commercial builds reject service overrides (CT_ERR_INVALID_ARG). */
CT_API int CtUpdateConfig(CtCore* core, const char* config_json);

/**
 * Create a share. paths_json: ["/abs/file", "/abs/dir", ...].
 * options_json: {"mode": "once"|"open", "ttl_sec": 600} (optional).
 * Emits share_state events; the returned id is available immediately.
 * out_share_id receives a malloc'd string (free with CtFreeString) or NULL.
 */
CT_API int CtShareCreate(CtCore* core, const char* paths_json,
                         const char* options_json, const char** out_share_id);
CT_API int CtShareClose(CtCore* core, const char* share_id);

/**
 * Claim a take-code (any accepted spelling, or an https:// / crosstransfer://
 * link) and receive into save_dir (NULL = configured default). If an
 * unfinished transfer for the same code exists in transfers.json it resumes.
 * out_transfer_id receives a malloc'd string or NULL.
 */
CT_API int CtReceiveStart(CtCore* core, const char* code_or_link,
                          const char* save_dir, const char** out_transfer_id);

/** Resume an unfinished receive listed by CtQuery {"what":"transfers"}. */
CT_API int CtReceiveResume(CtCore* core, const char* transfer_id);

CT_API int CtTransferPause(CtCore* core, const char* transfer_id);
CT_API int CtTransferResume(CtCore* core, const char* transfer_id);
CT_API int CtTransferCancel(CtCore* core, const char* transfer_id);

/**
 * Snapshot query. query_json: {"what": "shares"|"receives"|"transfers"|"config"|"all"}.
 * Returns a malloc'd JSON string (free with CtFreeString) or NULL.
 */
CT_API const char* CtQuery(CtCore* core, const char* query_json);

CT_API void CtFreeString(const char* s);

CT_API const char* CtVersion(void);

#ifdef __cplusplus
}
#endif

#endif /* CROSSTRANSFER_CT_API_H_ */
