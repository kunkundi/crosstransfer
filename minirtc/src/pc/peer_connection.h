/*
 * Copyright (c) 2024-2026 by DI JUNKUN, All Rights Reserved.
 */

#ifndef MINIRTC_PEER_CONNECTION_H_
#define MINIRTC_PEER_CONNECTION_H_

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

#include "clock/system_clock.h"
#include "data_transport.h"
#include "dtls_transport.h"
#include "ice_agent.h"
#include "minirtc.h"
#include "task_queue.h"
#include "thread_base.h"
#include "ws_client.h"

namespace minirtc {

// Owned copy of MiniRtcParams.
struct PeerParams {
  std::string server_host;
  int server_port = 0;
  bool server_tls = true;
  std::string server_path = "/ws";
  std::string log_dir = "logs";
  MiniRtcTurnMode turn_mode = MINIRTC_TURN_AUTO;
  bool enable_srtp = true;
  bool enable_upnp = false;
  bool enable_ws_relay = true;
  bool force_ws_relay = false;
  int ice_timeout_ms = 15000;
  std::string app, version, platform;

  MiniRtcOnSignalStatus on_signal_status = nullptr;
  MiniRtcOnShareEvent on_share_event = nullptr;
  MiniRtcOnClaimResult on_claim_result = nullptr;
  MiniRtcOnSessionStatus on_session_status = nullptr;
  MiniRtcOnReceiveData on_receive_data = nullptr;
  MiniRtcOnNetStats on_net_stats = nullptr;
  void* user_data = nullptr;
  MiniRtcOnNotifications on_notifications = nullptr;
};

// One WSS connection, N sessions. Implements signaling protocol v1
// (docs/PLAN.md part three) on the client side.
class PeerConnection : public ThreadBase {
 public:
  explicit PeerConnection(PeerParams params);
  ~PeerConnection();

  int AddDataStream(const std::string& name, bool reliable);
  int SetReliableWindow(const std::string& name, int wnd);

  int Connect();
  int Disconnect();

  int CreateShare(const std::string& mode, int ttl_sec,
                  const std::string& meta_json);
  int CloseShare(const std::string& share_id);
  int Claim(const std::string& code, const std::string& resume_token);
  int Leave(const std::string& session_id);

  int Send(const std::string& session_id, const std::string& stream,
           const uint8_t* data, size_t size);
  int GetLinkEstimate(const std::string& session_id, MiniRtcLinkEstimate* out);

 private:
  struct Session;
  using SessionPtr = std::shared_ptr<Session>;

  enum class Pending { kCreateShare, kClaim, kCloseShare, kLeave, kSignal };

  bool Process() override;  // 100 ms housekeeping (posted to worker_)
  void Housekeeping();
  // All session state changes run on worker_ so libjuice / WebSocket / pacer
  // threads never block on each other.
  void Post(AnyInvocable<void()> task);

  // signaling
  void OnWsStatus(WsStatus status);
  void OnWsText(const std::string& text);
  void OnWsBinary(const uint8_t* data, size_t size);
  int64_t SendRequest(nlohmann::json& msg, Pending kind);
  void SendSignal(const Session& s, nlohmann::json payload);
  void HandleWelcome(const nlohmann::json& j);
  void HandleShareCreated(const nlohmann::json& j);
  void HandleShareClosed(const nlohmann::json& j);
  void HandleSessionStart(const nlohmann::json& j);
  void HandleSessionEnd(const nlohmann::json& j);
  void HandleSignal(const nlohmann::json& j);
  void HandleError(const nlohmann::json& j);
  static std::vector<IceServer> ParseIceServers(const nlohmann::json& j);

  // sessions
  SessionPtr FindSession(const std::string& id) const;
  void StartSession(const SessionPtr& s);
  void SendLocalDescription(const SessionPtr& s, const char* kind);
  bool ApplyRemoteDescription(const SessionPtr& s, const std::string& sdp);
  void OnIceState(const SessionPtr& s, IceState state);
  void OnIceCandidate(const SessionPtr& s, const std::string& line);
  void OnIceGatheringDone(const SessionPtr& s);
  void OnPathDatagram(const SessionPtr& s, const uint8_t* data, size_t size);
  void MaybeStartDtls(const SessionPtr& s);
  void OnDtlsDone(const SessionPtr& s, bool verified);
  void EndSessionAsync(const SessionPtr& s, MiniRtcSessionStatus status,
                       const std::string& reason, bool notify_server);
  void OnPathReady(const SessionPtr& s);
  void SwitchToRelay(const SessionPtr& s, const char* why);
  void EndSession(const SessionPtr& s, MiniRtcSessionStatus status,
                  const std::string& reason, bool notify_server);
  void EndAllSessions(const std::string& reason);
  void NotifySession(const Session& s, MiniRtcSessionStatus status,
                     const std::string& reason);
  void NotifyShare(MiniRtcShareEvent ev, const std::string& share_id,
                   const std::string& code, int64_t expires_at,
                   const std::string& detail);
  void NotifyClaim(MiniRtcClaimResult r, const std::string& session_id,
                   const std::string& token, const std::string& message);

  PeerParams params_;
  std::shared_ptr<SystemClock> clock_;
  std::shared_ptr<TaskQueue> worker_;
  std::shared_ptr<WsClient> ws_;
  std::atomic<bool> housekeeping_pending_{false};
  std::vector<DataStreamConfig> streams_;

  std::atomic<bool> connected_{false};
  std::atomic<bool> hello_sent_{false};
  std::string peer_id_;
  std::vector<IceServer> ice_servers_;
  std::atomic<int64_t> next_request_id_{1};

  std::mutex pending_mutex_;
  std::map<int64_t, Pending> pending_;

  mutable std::shared_mutex sessions_mutex_;
  std::map<std::string, SessionPtr> sessions_;
  std::mutex signal_mutex_;
};

}  // namespace minirtc

#endif
