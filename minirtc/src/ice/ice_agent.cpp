/*
 * Copyright (c) 2026 by DI JUNKUN, All Rights Reserved.
 */

#include "ice_agent.h"

#include <miniupnpc/miniupnpc.h>
#include <miniupnpc/upnpcommands.h>
#include <miniupnpc/upnperrors.h>

#include <cstdlib>
#include <cstring>
#include <sstream>

#include "log.h"

namespace minirtc {

const char* IceStateName(IceState s) {
  switch (s) {
    case IceState::kNew:
      return "new";
    case IceState::kGathering:
      return "gathering";
    case IceState::kConnecting:
      return "connecting";
    case IceState::kConnected:
      return "connected";
    case IceState::kCompleted:
      return "completed";
    case IceState::kFailed:
      return "failed";
  }
  return "?";
}

namespace {

IceState FromJuice(juice_state_t s) {
  switch (s) {
    case JUICE_STATE_DISCONNECTED:
      return IceState::kNew;
    case JUICE_STATE_GATHERING:
      return IceState::kGathering;
    case JUICE_STATE_CONNECTING:
      return IceState::kConnecting;
    case JUICE_STATE_CONNECTED:
      return IceState::kConnected;
    case JUICE_STATE_COMPLETED:
      return IceState::kCompleted;
    case JUICE_STATE_FAILED:
      return IceState::kFailed;
  }
  return IceState::kFailed;
}

void JuiceLog(juice_log_level_t level, const char* message) {
  switch (level) {
    case JUICE_LOG_LEVEL_WARN:
      LOG_WARN("[juice] {}", message);
      break;
    case JUICE_LOG_LEVEL_ERROR:
    case JUICE_LOG_LEVEL_FATAL:
      LOG_ERROR("[juice] {}", message);
      break;
    default:
      LOG_INFO("[juice] {}", message);
      break;
  }
}

std::once_flag g_juice_log_once;

// Parses "a=candidate:F 1 UDP prio ADDR PORT typ TYPE ..." → (addr, port, type).
bool ParseCandidate(const std::string& line, std::string& addr, uint16_t& port,
                    std::string& type) {
  std::string s = line;
  if (s.rfind("a=", 0) == 0) s.erase(0, 2);
  if (s.rfind("candidate:", 0) != 0) return false;
  std::istringstream is(s.substr(10));
  std::string foundation, component, transport, prio, typ;
  int p = 0;
  if (!(is >> foundation >> component >> transport >> prio >> addr >> p >> typ >>
        type))
    return false;
  if (p <= 0 || p > 65535) return false;
  port = static_cast<uint16_t>(p);
  return true;
}

}  // namespace

IceAgent::IceAgent(const IceConfig& config, Callbacks callbacks)
    : config_(config), callbacks_(std::move(callbacks)) {
  std::call_once(g_juice_log_once, []() {
    juice_set_log_handler(&JuiceLog);
    juice_set_log_level(std::getenv("MINIRTC_JUICE_DEBUG") ? JUICE_LOG_LEVEL_DEBUG
                                                           : JUICE_LOG_LEVEL_WARN);
  });

  juice_config_t jc{};
  jc.concurrency_mode = JUICE_CONCURRENCY_MODE_THREAD;
  jc.cb_state_changed = &IceAgent::OnStateStatic;
  jc.cb_candidate = &IceAgent::OnCandidateStatic;
  jc.cb_gathering_done = &IceAgent::OnGatheringDoneStatic;
  jc.cb_recv = &IceAgent::OnRecvStatic;
  jc.user_ptr = this;

  uint16_t stun_port = 0;
  for (const auto& s : config_.servers) {
    if (!s.turn) {
      if (stun_host_.empty()) {
        stun_host_ = s.host;
        stun_port = s.port;
      }
    } else if (config_.turn_mode != MINIRTC_TURN_DISABLED) {
      turn_hosts_.push_back(s.host);
      turn_users_.push_back(s.username);
      turn_passwords_.push_back(s.password);
    }
  }
  if (!stun_host_.empty() && config_.turn_mode != MINIRTC_TURN_FORCE) {
    jc.stun_server_host = stun_host_.c_str();
    jc.stun_server_port = stun_port;
  }
  for (size_t i = 0; i < turn_hosts_.size(); ++i) {
    juice_turn_server_t t{};
    t.host = turn_hosts_[i].c_str();
    t.username = turn_users_[i].c_str();
    t.password = turn_passwords_[i].c_str();
    t.port = 0;
    // Port is encoded in the host by ResolveTurn(); split here.
    turn_servers_.push_back(t);
  }
  // Ports: IceServer keeps host and port separately, patch after copy.
  for (size_t i = 0; i < turn_servers_.size(); ++i) {
    size_t idx = 0;
    for (const auto& s : config_.servers) {
      if (!s.turn || config_.turn_mode == MINIRTC_TURN_DISABLED) continue;
      if (idx == i) {
        turn_servers_[i].port = s.port;
        break;
      }
      ++idx;
    }
  }
  if (!turn_servers_.empty()) {
    jc.turn_servers = turn_servers_.data();
    jc.turn_servers_count = static_cast<int>(turn_servers_.size());
  }
  if (!config_.bind_address.empty()) {
    jc.bind_address = config_.bind_address.c_str();
  }

  agent_ = juice_create(&jc);
  if (!agent_) {
    LOG_ERROR("juice_create failed");
    state_ = IceState::kFailed;
  } else {
    receive_thread_ = std::thread([this] { ReceiveLoop(); });
    LOG_INFO("ICE agent created stun=[{}] turn_servers={} turn_mode={}",
             stun_host_, turn_servers_.size(), static_cast<int>(config_.turn_mode));
  }
}

IceAgent::~IceAgent() { Close(); }

void IceAgent::Close() {
  if (closed_.exchange(true)) return;
  StopUpnpMapping();
  juice_agent_t* agent = nullptr;
  {
    std::unique_lock<std::shared_mutex> lock(mutex_);
    agent = agent_;
    agent_ = nullptr;
  }
  if (agent) {
    juice_destroy(agent);
  }
  {
    std::lock_guard<std::mutex> lock(receive_mutex_);
    receive_queue_.clear();
    receive_bytes_ = 0;
  }
  receive_cv_.notify_all();
  if (receive_thread_.joinable()) receive_thread_.join();
}

std::string IceAgent::LocalDescription() const {
  std::shared_lock<std::shared_mutex> lock(mutex_);
  if (!agent_) return {};
  char buf[JUICE_MAX_SDP_STRING_LEN];
  if (juice_get_local_description(agent_, buf, sizeof(buf)) != JUICE_ERR_SUCCESS)
    return {};
  // Keep only the ICE attributes; every candidate (including host candidates
  // gathered synchronously) is trickled through on_candidate so the same
  // policy (relay-only filtering, UPnP) applies to all of them.
  std::istringstream lines(buf);
  std::string line, out;
  while (std::getline(lines, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty() || line.rfind("a=candidate:", 0) == 0 ||
        line.rfind("a=end-of-candidates", 0) == 0)
      continue;
    out += line + "\r\n";
  }
  return out;
}

int IceAgent::GatherCandidates() {
  std::shared_lock<std::shared_mutex> lock(mutex_);
  if (!agent_) return -1;
  return juice_gather_candidates(agent_) == JUICE_ERR_SUCCESS ? 0 : -1;
}

int IceAgent::SetRemoteDescription(const std::string& sdp) {
  std::shared_lock<std::shared_mutex> lock(mutex_);
  if (!agent_) return -1;
  const int r = juice_set_remote_description(agent_, sdp.c_str());
  if (r != JUICE_ERR_SUCCESS) {
    LOG_ERROR("juice_set_remote_description failed: {}", r);
    return -1;
  }
  return 0;
}

int IceAgent::AddRemoteCandidate(const std::string& candidate_line) {
  std::shared_lock<std::shared_mutex> lock(mutex_);
  if (!agent_) return -1;
  // In forced-relay mode ignore anything but relay candidates from the peer
  // so the connection cannot escape the TURN path.
  if (config_.turn_mode == MINIRTC_TURN_FORCE) {
    std::string addr, type;
    uint16_t port = 0;
    if (ParseCandidate(candidate_line, addr, port, type) && type != "relay") {
      return 0;
    }
  }
  const int r = juice_add_remote_candidate(agent_, candidate_line.c_str());
  if (r == JUICE_ERR_IGNORED) return 0;
  return r == JUICE_ERR_SUCCESS ? 0 : -1;
}

int IceAgent::SetRemoteGatheringDone() {
  std::shared_lock<std::shared_mutex> lock(mutex_);
  if (!agent_) return -1;
  return juice_set_remote_gathering_done(agent_) == JUICE_ERR_SUCCESS ? 0 : -1;
}

int IceAgent::Send(const uint8_t* data, size_t size) {
  if (closed_.load() || !data || size == 0) return -1;
  // TURN sends also take libjuice's connection lock. Receive callbacks must
  // not hold that lock while entering the transport's own locks.
  std::shared_lock<std::shared_mutex> lock(mutex_);
  juice_agent_t* agent = agent_;
  if (!agent) return -1;
  const IceState st = state_.load();
  if (st != IceState::kConnected && st != IceState::kCompleted) return -1;
  const int r = juice_send(agent, reinterpret_cast<const char*>(data), size);
  return r == JUICE_ERR_SUCCESS ? 0 : (r == JUICE_ERR_AGAIN ? 1 : -1);
}

bool IceAgent::SelectedPairUsesRelay() const {
  std::shared_lock<std::shared_mutex> lock(mutex_);
  if (!agent_) return false;
  char local[JUICE_MAX_CANDIDATE_SDP_STRING_LEN];
  char remote[JUICE_MAX_CANDIDATE_SDP_STRING_LEN];
  if (juice_get_selected_candidates(agent_, local, sizeof(local), remote,
                                    sizeof(remote)) != JUICE_ERR_SUCCESS)
    return false;
  return std::strstr(local, "typ relay") != nullptr ||
         std::strstr(remote, "typ relay") != nullptr;
}

std::string IceAgent::SelectedPairDescription() const {
  std::shared_lock<std::shared_mutex> lock(mutex_);
  if (!agent_) return {};
  char local[JUICE_MAX_CANDIDATE_SDP_STRING_LEN];
  char remote[JUICE_MAX_CANDIDATE_SDP_STRING_LEN];
  if (juice_get_selected_candidates(agent_, local, sizeof(local), remote,
                                    sizeof(remote)) != JUICE_ERR_SUCCESS)
    return {};
  return std::string(local) + " <-> " + remote;
}

void IceAgent::OnStateStatic(juice_agent_t*, juice_state_t state, void* user) {
  auto* self = static_cast<IceAgent*>(user);
  if (!self || self->closed_.load()) return;
  const IceState s = FromJuice(state);
  self->state_.store(s);
  if (self->callbacks_.on_state) self->callbacks_.on_state(s);
}

void IceAgent::OnCandidateStatic(juice_agent_t*, const char* sdp, void* user) {
  auto* self = static_cast<IceAgent*>(user);
  if (!self || self->closed_.load() || !sdp) return;
  std::string line(sdp);
  std::string addr, type;
  uint16_t port = 0;
  const bool parsed = ParseCandidate(line, addr, port, type);
  if (self->config_.turn_mode == MINIRTC_TURN_FORCE && parsed &&
      type != "relay") {
    return;  // relay only
  }
  if (parsed && type == "host" && self->config_.enable_upnp &&
      addr.find(':') == std::string::npos) {
    self->StartUpnpMapping(port);
  }
  if (self->callbacks_.on_candidate) self->callbacks_.on_candidate(line);
}

void IceAgent::OnGatheringDoneStatic(juice_agent_t*, void* user) {
  auto* self = static_cast<IceAgent*>(user);
  if (!self || self->closed_.load()) return;
  if (self->callbacks_.on_gathering_done) self->callbacks_.on_gathering_done();
}

void IceAgent::OnRecvStatic(juice_agent_t*, const char* data, size_t size,
                            void* user) {
  auto* self = static_cast<IceAgent*>(user);
  if (!self || self->closed_.load() || !data || size == 0) return;
  {
    std::lock_guard<std::mutex> lock(self->receive_mutex_);
    if (self->closed_.load() || size > kMaxReceiveBytes - self->receive_bytes_ ||
        self->receive_queue_.size() >= kMaxReceivePackets) return;
    self->receive_queue_.emplace_back(data, data + size);
    self->receive_bytes_ += size;
  }
  self->receive_cv_.notify_one();
}

void IceAgent::ReceiveLoop() {
  for (;;) {
    std::vector<uint8_t> datagram;
    {
      std::unique_lock<std::mutex> lock(receive_mutex_);
      receive_cv_.wait(lock, [this] { return closed_.load() || !receive_queue_.empty(); });
      if (closed_.load()) return;
      datagram = std::move(receive_queue_.front());
      receive_queue_.pop_front();
      receive_bytes_ -= datagram.size();
    }
    if (!closed_.load() && callbacks_.on_recv) callbacks_.on_recv(datagram.data(), datagram.size());
  }
}

// ---------------------------------------------------------------------------
// UPnP IGD port mapping (best effort). When the gateway accepts the mapping the
// external address is advertised to the peer as an additional server-reflexive
// candidate; the remote ICE checks then reach us through the mapped port and
// libjuice pairs them as peer-reflexive.
// ---------------------------------------------------------------------------

void IceAgent::StartUpnpMapping(uint16_t local_port) {
  if (upnp_started_.exchange(true)) return;
  upnp_thread_ = std::thread([this, local_port]() {
    int error = 0;
    UPNPDev* devlist = upnpDiscover(1500, nullptr, nullptr, 0, 0, 2, &error);
    if (!devlist) {
      LOG_INFO("UPnP: no IGD found (err={})", error);
      return;
    }
    UPNPUrls urls{};
    IGDdatas data{};
    char lanaddr[64] = {0};
    char wanaddr[64] = {0};
    const int igd = UPNP_GetValidIGD(devlist, &urls, &data, lanaddr,
                                     sizeof(lanaddr), wanaddr, sizeof(wanaddr));
    freeUPNPDevlist(devlist);
    if (igd != 1) {
      LOG_INFO("UPnP: IGD status {} (not connected)", igd);
      if (igd != 0) FreeUPNPUrls(&urls);
      return;
    }
    char ext_ip[64] = {0};
    if (UPNP_GetExternalIPAddress(urls.controlURL, data.first.servicetype,
                                  ext_ip) != UPNPCOMMAND_SUCCESS ||
        ext_ip[0] == '\0') {
      LOG_INFO("UPnP: external IP unavailable");
      FreeUPNPUrls(&urls);
      return;
    }
    const std::string port = std::to_string(local_port);
    const int r = UPNP_AddPortMapping(urls.controlURL, data.first.servicetype,
                                      port.c_str(), port.c_str(), lanaddr,
                                      "CrossTransfer", "UDP", nullptr, "3600");
    if (r != UPNPCOMMAND_SUCCESS) {
      LOG_INFO("UPnP: AddPortMapping failed: {}", strupnperror(r));
      FreeUPNPUrls(&urls);
      return;
    }
    {
      std::lock_guard<std::mutex> lock(upnp_mutex_);
      upnp_control_url_ = urls.controlURL;
      upnp_service_type_ = data.first.servicetype;
      upnp_external_port_ = port;
    }
    FreeUPNPUrls(&urls);
    LOG_INFO("UPnP: mapped UDP {}:{} -> {}:{}", ext_ip, port, lanaddr, port);
    if (closed_.load()) return;
    // srflx-like priority: type pref 100.
    const uint32_t priority = (100u << 24) | (65535u << 8) | 255u;
    std::ostringstream cand;
    cand << "a=candidate:upnp 1 UDP " << priority << " " << ext_ip << " "
         << port << " typ srflx raddr 0.0.0.0 rport 0";
    if (callbacks_.on_candidate) callbacks_.on_candidate(cand.str());
  });
}

void IceAgent::StopUpnpMapping() {
  if (upnp_thread_.joinable()) upnp_thread_.join();
  std::string url, service, port;
  {
    std::lock_guard<std::mutex> lock(upnp_mutex_);
    url.swap(upnp_control_url_);
    service.swap(upnp_service_type_);
    port.swap(upnp_external_port_);
  }
  if (!url.empty()) {
    UPNP_DeletePortMapping(url.c_str(), service.c_str(), port.c_str(), "UDP",
                           nullptr);
  }
}

}  // namespace minirtc
