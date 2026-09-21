/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "runtime/peer.h"

#include <cstdint>
#include <cstring>

#include "log/log.h"
#include "transfer/protocol.h"

namespace ct {

// Shared between the Peer and MiniRTC callbacks (user_data). Callbacks take
// the shared lock, check `open`, and dispatch. Close() takes the exclusive
// lock and flips `open`, after which no callback touches the Peer.
struct Peer::Gate {
  std::shared_mutex mutex;
  bool open = true;
  Peer* peer = nullptr;
  std::shared_mutex sinks_mutex;
  std::map<std::string, std::shared_ptr<DataSink>> sinks;
};

namespace {

std::string S(const char* s) { return s ? s : ""; }

}  // namespace

Peer::Peer(EventLoop* loop, const PeerConfig& cfg, Callbacks cbs)
    : loop_(loop), cfg_(cfg), cbs_(std::move(cbs)), gate_(std::make_shared<Gate>()) {
  gate_->peer = this;
}

Peer::~Peer() { Close(true); }

bool Peer::Connect(std::string* error) {
  std::unique_lock<std::shared_mutex> gate_lock(gate_->mutex);
  std::lock_guard<std::mutex> lock(peer_mutex_);
  if (peer_) return true;
  if (!gate_->open) {
    if (error) *error = "peer closed";
    return false;
  }
  MiniRtcParams p{};
  p.server_host = cfg_.server_host.c_str();
  p.server_port = cfg_.server_port;
  p.server_tls = cfg_.server_tls;
  p.server_path = cfg_.server_path.c_str();
  p.log_dir = cfg_.log_dir.c_str();
  p.turn_mode = cfg_.turn_mode;
  p.enable_srtp = cfg_.enable_srtp;
  p.enable_upnp = cfg_.enable_upnp;
  p.enable_ws_relay = cfg_.enable_ws_relay;
  p.force_ws_relay = cfg_.force_ws_relay;
  p.ice_timeout_ms = cfg_.ice_timeout_ms;
  p.app = cfg_.app.c_str();
  p.version = cfg_.version.c_str();
  p.platform = cfg_.platform.c_str();
  p.on_signal_status = &Peer::OnSignalStatus;
  p.on_share_event = &Peer::OnShareEvent;
  p.on_claim_result = &Peer::OnClaimResult;
  p.on_session_status = &Peer::OnSessionStatus;
  p.on_receive_data = &Peer::OnReceiveData;
  p.on_net_stats = &Peer::OnNetStats;
  // The gate outlives the MiniRtcPeer: we hold a raw pointer to a heap
  // object kept alive by gate_ (and by the teardown thread).
  p.user_data = gate_.get();
  peer_ = MiniRtcCreate(&p);
  if (!peer_) {
    if (error) *error = "MiniRtcCreate failed";
    return false;
  }
  MiniRtcAddDataStream(peer_, kStreamCtrl, true);
  MiniRtcAddDataStream(peer_, kStreamData, false);
  MiniRtcAddDataStream(peer_, kStreamSack, false);
  MiniRtcSetReliableWindow(peer_, kStreamCtrl, cfg_.kcp_window);
  if (MiniRtcConnect(peer_) != 0) {
    if (error) *error = "MiniRtcConnect failed";
    MiniRtcDestroy(&peer_);
    peer_ = nullptr;
    return false;
  }
  return true;
}

void Peer::Close(bool wait) {
  MiniRtcPeer* p = nullptr;
  {
    // Exclusive gate first: no callback or Send() is inside MiniRTC once we
    // hold it, and none can enter afterwards.
    std::unique_lock<std::shared_mutex> lock(gate_->mutex);
    gate_->open = false;
    gate_->peer = nullptr;
    std::lock_guard<std::mutex> pl(peer_mutex_);
    p = peer_;
    peer_ = nullptr;
  }
  {
    std::unique_lock<std::shared_mutex> lock(gate_->sinks_mutex);
    gate_->sinks.clear();
  }
  if (!p) return;
  auto gate = gate_;  // keep user_data alive while MiniRTC winds down
  auto destroy = [p, gate]() mutable {
    MiniRtcPeer* tmp = p;
    MiniRtcDestroy(&tmp);
    (void)gate;
  };
  if (wait) {
    destroy();
  } else {
    std::thread(destroy).detach();
  }
}

int Peer::CreateShare(const std::string& mode, int ttl_sec, const std::string& meta_json) {
  std::lock_guard<std::mutex> lock(peer_mutex_);
  if (!peer_) return -1;
  return MiniRtcCreateShare(peer_, mode.c_str(), ttl_sec, meta_json.c_str());
}

int Peer::CloseShare(const std::string& share_id) {
  std::lock_guard<std::mutex> lock(peer_mutex_);
  if (!peer_) return -1;
  return MiniRtcCloseShare(peer_, share_id.c_str());
}

int Peer::Claim(const std::string& code, const std::string& resume_token) {
  std::lock_guard<std::mutex> lock(peer_mutex_);
  if (!peer_) return -1;
  return MiniRtcClaim(peer_, code.empty() ? nullptr : code.c_str(),
                      resume_token.empty() ? nullptr : resume_token.c_str());
}

int Peer::Leave(const std::string& session_id) {
  std::lock_guard<std::mutex> lock(peer_mutex_);
  if (!peer_) return -1;
  return MiniRtcLeave(peer_, session_id.c_str());
}

int Peer::Send(const std::string& session_id, const char* stream, const void* data, size_t len) {
  // MiniRtcSend is internally synchronised; avoid peer_mutex_ on the hot
  // path but guard against use after Close.
  std::shared_lock<std::shared_mutex> lock(gate_->mutex);
  if (!gate_->open) return -1;
  MiniRtcPeer* p = peer_;
  if (!p) return -1;
  return MiniRtcSend(p, session_id.c_str(), stream, data, len);
}

bool Peer::GetLinkEstimate(const std::string& session_id, MiniRtcLinkEstimate* out) {
  std::shared_lock<std::shared_mutex> lock(gate_->mutex);
  if (!gate_->open || !peer_) return false;
  return MiniRtcGetLinkEstimate(peer_, session_id.c_str(), out) == 0;
}

void Peer::SetDataSink(const std::string& session_id, std::shared_ptr<DataSink> sink) {
  std::unique_lock<std::shared_mutex> lock(gate_->sinks_mutex);
  gate_->sinks[session_id] = std::move(sink);
}

void Peer::RemoveDataSink(const std::string& session_id, const DataSink* expected) {
  std::unique_lock<std::shared_mutex> lock(gate_->sinks_mutex);
  auto it = gate_->sinks.find(session_id);
  if (it != gate_->sinks.end() && it->second.get() == expected) gate_->sinks.erase(it);
}

// ---- static callbacks (MiniRTC threads) -------------------------------------

#define CT_PEER_GATE(ud)                                          \
  auto* gate = static_cast<Gate*>(ud);                            \
  std::shared_lock<std::shared_mutex> gate_lock(gate->mutex);     \
  if (!gate->open || !gate->peer) return;                         \
  Peer* self = gate->peer;

void Peer::OnSignalStatus(MiniRtcSignalStatus st, const char* peer_id, void* ud) {
  CT_PEER_GATE(ud)
  std::string pid = S(peer_id);
  self->loop_->Post([self, st, pid]() {
    if (self->cbs_.on_signal) self->cbs_.on_signal(st, pid);
  });
}

void Peer::OnShareEvent(MiniRtcShareEvent ev, const char* share_id, const char* code,
                        int64_t expires_at, const char* detail, void* ud) {
  CT_PEER_GATE(ud)
  std::string sid = S(share_id), c = S(code), d = S(detail);
  self->loop_->Post([self, ev, sid, c, expires_at, d]() {
    if (self->cbs_.on_share) self->cbs_.on_share(ev, sid, c, expires_at, d);
  });
}

void Peer::OnClaimResult(MiniRtcClaimResult r, const char* session_id, const char* token,
                         const char* message, void* ud) {
  CT_PEER_GATE(ud)
  std::string sid = S(session_id), t = S(token), m = S(message);
  self->loop_->Post([self, r, sid, t, m]() {
    if (self->cbs_.on_claim) self->cbs_.on_claim(r, sid, t, m);
  });
}

void Peer::OnSessionStatus(MiniRtcSessionStatus st, const char* sid, const char* role,
                           const char* token, const char* meta, MiniRtcPath path,
                           const char* reason, void* ud) {
  CT_PEER_GATE(ud)
  SessionInfo info;
  info.status = st;
  info.session_id = S(sid);
  info.role = S(role);
  info.resume_token = S(token);
  info.meta_json = S(meta);
  info.path = path;
  info.reason = S(reason);
  self->loop_->Post([self, info]() {
    if (self->cbs_.on_session) self->cbs_.on_session(info);
  });
}

void Peer::OnReceiveData(const uint8_t* data, size_t len, const char* sid, const char* stream,
                         void* ud) {
  auto* gate = static_cast<Gate*>(ud);
  if (!data || !sid || !stream) return;
  if (std::strcmp(stream, kStreamCtrl) == 0) {
    std::shared_lock<std::shared_mutex> gate_lock(gate->mutex);
    if (!gate->open || !gate->peer) return;
    Peer* self = gate->peer;
    std::string session(sid);
    std::string payload(reinterpret_cast<const char*>(data), len);
    self->loop_->Post([self, session, payload = std::move(payload)]() mutable {
      if (self->cbs_.on_ctrl) self->cbs_.on_ctrl(session, std::move(payload));
    });
    return;
  }
  std::shared_ptr<DataSink> sink;
  {
    std::shared_lock<std::shared_mutex> lock(gate->sinks_mutex);
    auto it = gate->sinks.find(sid);
    if (it == gate->sinks.end()) return;
    sink = it->second;
  }
  sink->OnData(stream, data, len);
}

void Peer::OnNetStats(const char* sid, const MiniRtcNetStats* stats, void* ud) {
  CT_PEER_GATE(ud)
  if (!stats) return;
  std::string session = S(sid);
  MiniRtcNetStats copy = *stats;
  self->loop_->Post([self, session, copy]() {
    if (self->cbs_.on_stats) self->cbs_.on_stats(session, copy);
  });
}

#undef CT_PEER_GATE

const char* Peer::SignalStatusName(MiniRtcSignalStatus s) {
  switch (s) {
    case MINIRTC_SIGNAL_CONNECTING: return "connecting";
    case MINIRTC_SIGNAL_CONNECTED: return "connected";
    case MINIRTC_SIGNAL_FAILED: return "failed";
    case MINIRTC_SIGNAL_CLOSED: return "closed";
    case MINIRTC_SIGNAL_RECONNECTING: return "reconnecting";
    case MINIRTC_SIGNAL_TLS_ERROR: return "tls_error";
  }
  return "unknown";
}

const char* Peer::SessionStatusName(MiniRtcSessionStatus s) {
  switch (s) {
    case MINIRTC_SESSION_CONNECTING: return "connecting";
    case MINIRTC_SESSION_CONNECTED: return "connected";
    case MINIRTC_SESSION_DISCONNECTED: return "disconnected";
    case MINIRTC_SESSION_FAILED: return "failed";
    case MINIRTC_SESSION_CLOSED: return "closed";
  }
  return "unknown";
}

const char* Peer::PathName(MiniRtcPath p) {
  switch (p) {
    case MINIRTC_PATH_P2P: return "p2p";
    case MINIRTC_PATH_TURN: return "turn";
    case MINIRTC_PATH_WS_RELAY: return "relay";
    case MINIRTC_PATH_UNKNOWN: break;
  }
  return "unknown";
}

const char* Peer::ClaimResultName(MiniRtcClaimResult r) {
  switch (r) {
    case MINIRTC_CLAIM_OK: return "ok";
    case MINIRTC_CLAIM_CODE_NOT_FOUND: return "code_not_found";
    case MINIRTC_CLAIM_CODE_EXPIRED: return "code_expired";
    case MINIRTC_CLAIM_SHARE_BUSY: return "share_busy";
    case MINIRTC_CLAIM_RATE_LIMITED: return "rate_limited";
    case MINIRTC_CLAIM_ERROR: break;
  }
  return "error";
}

}  // namespace ct
