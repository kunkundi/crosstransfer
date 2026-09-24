/*
 * CrossTransfer core — MiniRTC peer wrapper.
 *
 * Owns one MiniRtcPeer (one signaling connection). Control callbacks
 * (signal / share / claim / session / stats) are copied and posted to the
 * core EventLoop. Data callbacks for the unreliable streams are delivered
 * synchronously on the MiniRTC thread to a per-session DataSink registered
 * by the transfer engine (no allocation per packet beyond the sink's own).
 *
 * A gate protects against callbacks racing with destruction: after Close()
 * no callback reaches the owner even if MiniRTC threads are still winding
 * down.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_RUNTIME_PEER_H_
#define CT_RUNTIME_PEER_H_

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <thread>

#include "minirtc.h"
#include "runtime/event_loop.h"

namespace ct {

struct PeerConfig {
  std::string server_host;
  int server_port = 443;
  bool server_tls = true;
  std::string server_path = "/ws";
  std::string log_dir;
  MiniRtcTurnMode turn_mode = MINIRTC_TURN_AUTO;
  bool enable_srtp = true;
  bool enable_upnp = false;
  bool enable_ws_relay = true;
  bool force_ws_relay = false;
  int ice_timeout_ms = 15000;
  std::string app = "crosstransfer";
  std::string version;
  std::string platform;
  int kcp_window = 1024;
};

struct SessionInfo {
  MiniRtcSessionStatus status = MINIRTC_SESSION_CONNECTING;
  std::string session_id;
  std::string role;  // "sender" | "receiver"
  std::string resume_token;
  std::string meta_json;
  MiniRtcPath path = MINIRTC_PATH_UNKNOWN;
  std::string reason;
};

// Invoked on the MiniRTC thread. Must be fast and must not call back into
// the Peer control API.
class DataSink {
 public:
  virtual ~DataSink() = default;
  virtual void OnData(const std::string& stream, const uint8_t* data, size_t len) = 0;
};

class Peer {
 public:
  struct Callbacks {
    std::function<void(const std::string&)> on_notifications;
    std::function<void(MiniRtcSignalStatus, const std::string& peer_id)> on_signal;
    std::function<void(MiniRtcShareEvent, const std::string& share_id,
                       const std::string& code, int64_t expires_at,
                       const std::string& detail)>
        on_share;
    std::function<void(MiniRtcClaimResult, const std::string& session_id,
                       const std::string& resume_token, const std::string& message)>
        on_claim;
    std::function<void(const SessionInfo&)> on_session;
    std::function<void(const std::string& session_id, const MiniRtcNetStats&)> on_stats;
    // Reliable ctrl stream messages (already copied), posted to the loop.
    std::function<void(const std::string& session_id, std::string data)> on_ctrl;
  };

  Peer(EventLoop* loop, const PeerConfig& cfg, Callbacks cbs);
  ~Peer();
  Peer(const Peer&) = delete;
  Peer& operator=(const Peer&) = delete;

  // Registers streams and opens the signaling connection.
  bool Connect(std::string* error);
  // Closes the gate and tears the MiniRTC peer down. With wait == false the
  // teardown runs on a detached thread (UI responsiveness); with true the
  // call blocks until MiniRTC threads have joined.
  void Close(bool wait);

  int CreateShare(const std::string& mode, int ttl_sec, const std::string& meta_json);
  int CloseShare(const std::string& share_id);
  int Claim(const std::string& code, const std::string& resume_token);
  int Leave(const std::string& session_id);

  // Any thread. Returns 0 ok, 1 backpressure, -1 error.
  int Send(const std::string& session_id, const char* stream, const void* data, size_t len);
  bool GetLinkEstimate(const std::string& session_id, MiniRtcLinkEstimate* out);

  void SetDataSink(const std::string& session_id, std::shared_ptr<DataSink> sink);
  // Removes the sink only if it is still `expected` (a resumed session may
  // already have registered a new one under the same id).
  void RemoveDataSink(const std::string& session_id, const DataSink* expected);

  static const char* SignalStatusName(MiniRtcSignalStatus s);
  static const char* SessionStatusName(MiniRtcSessionStatus s);
  static const char* PathName(MiniRtcPath p);
  static const char* ClaimResultName(MiniRtcClaimResult r);

 private:
  struct Gate;
  static void OnNotifications(const char*, void*);
  static void OnSignalStatus(MiniRtcSignalStatus, const char*, void*);
  static void OnShareEvent(MiniRtcShareEvent, const char*, const char*, int64_t, const char*, void*);
  static void OnClaimResult(MiniRtcClaimResult, const char*, const char*, const char*, void*);
  static void OnSessionStatus(MiniRtcSessionStatus, const char*, const char*, const char*,
                              const char*, MiniRtcPath, const char*, void*);
  static void OnReceiveData(const uint8_t*, size_t, const char*, const char*, void*);
  static void OnNetStats(const char*, const MiniRtcNetStats*, void*);

  EventLoop* loop_;
  PeerConfig cfg_;
  Callbacks cbs_;
  std::shared_ptr<Gate> gate_;
  MiniRtcPeer* peer_ = nullptr;
  std::mutex peer_mutex_;
};

}  // namespace ct

#endif  // CT_RUNTIME_PEER_H_
