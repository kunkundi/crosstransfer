/*
 * Copyright (c) 2026 by DI JUNKUN, All Rights Reserved.
 */

#ifndef MINIRTC_ICE_AGENT_H_
#define MINIRTC_ICE_AGENT_H_

#include <juice/juice.h>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <thread>
#include <vector>

#include "minirtc.h"

namespace minirtc {

struct IceServer {
  std::string host;
  uint16_t port = 3478;
  bool turn = false;
  std::string username;
  std::string password;
};

struct IceConfig {
  std::vector<IceServer> servers;
  MiniRtcTurnMode turn_mode = MINIRTC_TURN_AUTO;
  bool enable_upnp = false;
  std::string bind_address;  // optional
};

enum class IceState {
  kNew,
  kGathering,
  kConnecting,
  kConnected,
  kCompleted,
  kFailed
};

const char* IceStateName(IceState s);

// State/candidate callbacks run on libjuice's thread. Received datagrams are
// delivered in order by our worker, outside libjuice's connection lock.
class IceAgent {
 public:
  struct Callbacks {
    std::function<void(IceState)> on_state;
    // Local candidate line "a=candidate:..." (no CRLF).
    std::function<void(const std::string&)> on_candidate;
    std::function<void()> on_gathering_done;
    std::function<void(const uint8_t*, size_t)> on_recv;
  };

  explicit IceAgent(const IceConfig& config, Callbacks callbacks);
  ~IceAgent();

  IceAgent(const IceAgent&) = delete;
  IceAgent& operator=(const IceAgent&) = delete;

  // ICE attributes and any already gathered candidates, as SDP lines.
  std::string LocalDescription() const;
  int GatherCandidates();
  int SetRemoteDescription(const std::string& sdp);
  int AddRemoteCandidate(const std::string& candidate_line);
  int SetRemoteGatheringDone();

  int Send(const uint8_t* data, size_t size);

  IceState State() const { return state_.load(); }
  // True once a relay candidate is part of the selected pair.
  bool SelectedPairUsesRelay() const;
  std::string SelectedPairDescription() const;

  // Stops sending and destroys the agent (joins libjuice threads).
  void Close();

 private:
  static void OnStateStatic(juice_agent_t*, juice_state_t, void*);
  static void OnCandidateStatic(juice_agent_t*, const char*, void*);
  static void OnGatheringDoneStatic(juice_agent_t*, void*);
  static void OnRecvStatic(juice_agent_t*, const char*, size_t, void*);
  void ReceiveLoop();

  void StartUpnpMapping(uint16_t local_port);
  void StopUpnpMapping();

  IceConfig config_;
  Callbacks callbacks_;
  std::vector<std::string> turn_hosts_;
  std::vector<std::string> turn_users_;
  std::vector<std::string> turn_passwords_;
  std::vector<juice_turn_server_t> turn_servers_;
  std::string stun_host_;

  juice_agent_t* agent_ = nullptr;
  std::atomic<IceState> state_{IceState::kNew};
  std::atomic<bool> closed_{false};
  // API calls hold this shared (they may run concurrently and may be invoked
  // from libjuice callbacks, which already hold libjuice's own lock); Close()
  // takes it exclusively to retire agent_. Holding it exclusively around a
  // juice_* call would invert the lock order against the callback thread.
  mutable std::shared_mutex mutex_;

  std::thread receive_thread_;
  std::mutex receive_mutex_;
  std::condition_variable receive_cv_;
  std::deque<std::vector<uint8_t>> receive_queue_;
  size_t receive_bytes_ = 0;
  static constexpr size_t kMaxReceiveBytes = 4u * 1024u * 1024u;
  static constexpr size_t kMaxReceivePackets = 4096;

  // UPnP
  std::thread upnp_thread_;
  std::atomic<bool> upnp_started_{false};
  std::mutex upnp_mutex_;
  std::string upnp_control_url_;
  std::string upnp_service_type_;
  std::string upnp_external_port_;
};

}  // namespace minirtc

#endif
