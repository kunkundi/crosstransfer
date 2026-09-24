/*
 * Copyright (c) 2024-2026 by DI JUNKUN, All Rights Reserved.
 */

#include "peer_connection.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <sstream>

#include "log.h"

namespace minirtc {

using nlohmann::json;

namespace {

constexpr int kProtoVersion = 1;
constexpr size_t kRelayHeaderSize = 2 + 1 + 1 + 16;
constexpr int64_t kDtlsTimeoutMs = 10000;

// Test-only link impairment, read once from the environment:
//   MINIRTC_TEST_DROP_PERCENT  drop N% of outgoing datagrams (0..100)
//   MINIRTC_TEST_LINK_KBPS     police outgoing datagrams to R kbit/s (excess dropped)
struct TestImpairment {
  int drop_percent = 0;
  int64_t link_kbps = 0;
  std::mutex mu;
  double tokens = 0;
  std::chrono::steady_clock::time_point last = std::chrono::steady_clock::now();
  uint32_t rng = 0x9E3779B9u;

  TestImpairment() {
    if (const char* v = std::getenv("MINIRTC_TEST_DROP_PERCENT")) drop_percent = std::atoi(v);
    if (const char* v = std::getenv("MINIRTC_TEST_LINK_KBPS")) link_kbps = std::atoll(v);
    if (drop_percent > 0 || link_kbps > 0) {
      LOG_WARN("TEST IMPAIRMENT ACTIVE: drop={}% link={} kbps", drop_percent, link_kbps);
    }
  }
  bool Active() const { return drop_percent > 0 || link_kbps > 0; }
  // Returns true when the datagram must be dropped.
  bool Drop(size_t bytes) {
    std::lock_guard<std::mutex> lock(mu);
    if (drop_percent > 0) {
      rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
      if (static_cast<int>(rng % 100) < drop_percent) return true;
    }
    if (link_kbps > 0) {
      const auto now = std::chrono::steady_clock::now();
      const double elapsed_ms = std::chrono::duration<double, std::milli>(now - last).count();
      last = now;
      const double burst = link_kbps * 1000.0 / 8.0 * 0.05;  // 50 ms bucket
      tokens = std::min(burst, tokens + elapsed_ms * link_kbps * 1000.0 / 8.0 / 1000.0);
      if (tokens < static_cast<double>(bytes)) return true;
      tokens -= static_cast<double>(bytes);
    }
    return false;
  }
};

TestImpairment& Impairment() {
  static TestImpairment t;
  return t;
}

std::string Str(const json& j, const char* key, const std::string& def = {}) {
  auto it = j.find(key);
  if (it == j.end() || !it->is_string()) return def;
  return it->get<std::string>();
}

int64_t Int(const json& j, const char* key, int64_t def = 0) {
  auto it = j.find(key);
  if (it == j.end() || !it->is_number()) return def;
  return it->get<int64_t>();
}

// a=fingerprint:sha-256 AA:BB:...
std::string ExtractFingerprint(const std::string& sdp) {
  std::istringstream lines(sdp);
  std::string line;
  while (std::getline(lines, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    const std::string prefix = "a=fingerprint:sha-256 ";
    if (line.rfind(prefix, 0) == 0) {
      std::string fp = line.substr(prefix.size());
      if (fp.size() != 95) return {};
      for (auto& c : fp) c = static_cast<char>(std::toupper((unsigned char)c));
      return fp;
    }
  }
  return {};
}

}  // namespace

// ---------------------------------------------------------------------------

struct PeerConnection::Session {
  std::string id;
  std::string share_id;
  std::string role;  // sender | receiver
  bool offerer = false;  // receiver sends the offer
  std::string remote_peer_id;
  std::string resume_token;
  std::string meta_json;
  std::vector<IceServer> ice_servers;

  std::unique_ptr<IceAgent> ice;
  std::unique_ptr<DtlsTransport> dtls;
  std::shared_ptr<DataTransport> data;

  std::mutex mutex;
  bool local_description_sent = false;
  bool remote_description_set = false;
  bool remote_gathering_done = false;
  std::vector<std::string> pending_remote_candidates;
  bool relay = false;          // WS relay in use
  bool path_ready = false;     // ICE connected or relay active
  bool transport_ready = false;
  bool ended = false;
  MiniRtcSessionStatus status = MINIRTC_SESSION_CONNECTING;
  int64_t created_ms = 0;
  int64_t dtls_started_ms = 0;
  int64_t last_stats_ms = 0;
  std::vector<uint8_t> relay_header;
};

PeerConnection::PeerConnection(PeerParams params)
    : params_(std::move(params)), clock_(std::make_shared<SystemClock>()) {
  SetPeriod(std::chrono::milliseconds(100));
  SetThreadName("PeerConnection");
}

PeerConnection::~PeerConnection() { Disconnect(); }

int PeerConnection::AddDataStream(const std::string& name, bool reliable) {
  if (connected_.load()) return -1;
  for (auto& s : streams_) {
    if (s.name == name) return 0;
  }
  DataStreamConfig cfg;
  cfg.name = name;
  cfg.reliable = reliable;
  streams_.push_back(cfg);
  return 0;
}

int PeerConnection::SetReliableWindow(const std::string& name, int wnd) {
  for (auto& s : streams_) {
    if (s.name == name) {
      if (!s.reliable || wnd < 16) return -1;
      s.kcp_window = wnd;
      return 0;
    }
  }
  return -1;
}

// ---- signaling connection ---------------------------------------------------

void PeerConnection::Post(AnyInvocable<void()> task) {
  if (worker_) worker_->PostTask(std::move(task));
}

int PeerConnection::Connect() {
  if (ws_) return 0;
  worker_ = std::make_shared<TaskQueue>("pc-worker");
  WsClient::Callbacks cb;
  cb.on_status = [this](WsStatus st) { Post([this, st]() { OnWsStatus(st); }); };
  cb.on_text = [this](const std::string& t) { Post([this, t]() { OnWsText(t); }); };
  cb.on_binary = [this](const uint8_t* d, size_t n) { OnWsBinary(d, n); };
  ws_ = std::make_shared<WsClient>(std::move(cb));
  std::ostringstream uri;
  uri << (params_.server_tls ? "wss://" : "ws://") << params_.server_host;
  if (params_.server_port > 0) uri << ":" << params_.server_port;
  uri << (params_.server_path.empty() ? "/ws" : params_.server_path);
  Start();
  return ws_->Connect(uri.str());
}

int PeerConnection::Disconnect() {
  Stop();
  if (worker_) worker_->Stop();  // drains queued session work
  EndAllSessions("local_close");
  if (ws_) {
    ws_->Shutdown();
    ws_.reset();
  }
  worker_.reset();
  connected_ = false;
  hello_sent_ = false;
  return 0;
}

void PeerConnection::OnWsStatus(WsStatus status) {
  MiniRtcSignalStatus out;
  switch (status) {
    case WsStatus::kConnecting:
      out = MINIRTC_SIGNAL_CONNECTING;
      break;
    case WsStatus::kOpen: {
      json hello = {{"type", "hello"},
                    {"id", next_request_id_++},
                    {"app", params_.app},
                    {"version", params_.version},
                    {"platform", params_.platform},
                    {"proto", kProtoVersion}};
      if (params_.on_notifications) hello["notifications"] = true;
      hello_sent_ = ws_->SendText(hello.dump());
      return;  // CONNECTED is reported on welcome
    }
    case WsStatus::kFailed:
      out = MINIRTC_SIGNAL_FAILED;
      break;
    case WsStatus::kClosed:
      out = MINIRTC_SIGNAL_CLOSED;
      break;
    case WsStatus::kReconnecting:
      out = MINIRTC_SIGNAL_RECONNECTING;
      break;
    case WsStatus::kTlsCertError:
      out = MINIRTC_SIGNAL_TLS_ERROR;
      break;
    default:
      return;
  }
  if (status != WsStatus::kConnecting) {
    // Any drop of the signaling connection invalidates the server-side peer;
    // sessions cannot be re-associated, so end them locally.
    connected_ = false;
    hello_sent_ = false;
    EndAllSessions("signal_lost");
  }
  if (params_.on_signal_status)
    params_.on_signal_status(out, peer_id_.c_str(), params_.user_data);
}

int64_t PeerConnection::SendRequest(json& msg, Pending kind) {
  if (!ws_ || !connected_.load()) return -1;
  const int64_t id = next_request_id_++;
  msg["id"] = id;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending_[id] = kind;
  }
  if (!ws_->SendText(msg.dump())) {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending_.erase(id);
    return -1;
  }
  return id;
}

void PeerConnection::OnWsText(const std::string& text) {
  json j;
  try {
    j = json::parse(text);
  } catch (const std::exception& e) {
    LOG_WARN("Bad signaling JSON: {}", e.what());
    return;
  }
  const std::string type = Str(j, "type");
  if (type == "welcome") {
    HandleWelcome(j);
  } else if (type == "notifications") {
    if (params_.on_notifications && j.contains("items") && j["items"].is_array() && j["items"].size() <= 50)
      params_.on_notifications(text.c_str(), params_.user_data);
  } else if (type == "share_created") {
    HandleShareCreated(j);
  } else if (type == "share_closed") {
    HandleShareClosed(j);
  } else if (type == "session_start") {
    HandleSessionStart(j);
  } else if (type == "session_end") {
    HandleSessionEnd(j);
  } else if (type == "signal") {
    HandleSignal(j);
  } else if (type == "error") {
    HandleError(j);
  } else if (type == "ok" || type == "pong") {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending_.erase(Int(j, "id", -1));
  } else if (type == "ping") {
    json pong = {{"type", "pong"}, {"id", Int(j, "id")}};
    if (ws_) ws_->SendText(pong.dump());
  } else {
    LOG_DEBUG("Ignoring signaling message type [{}]", type);
  }
}

std::vector<IceServer> PeerConnection::ParseIceServers(const json& j) {
  std::vector<IceServer> out;
  auto it = j.find("ice_servers");
  if (it == j.end() || !it->is_array()) return out;
  for (const auto& srv : *it) {
    auto urls = srv.find("urls");
    if (urls == srv.end() || !urls->is_array()) continue;
    for (const auto& u : *urls) {
      if (!u.is_string()) continue;
      std::string url = u.get<std::string>();
      IceServer s;
      if (url.rfind("stun:", 0) == 0) {
        url = url.substr(5);
      } else if (url.rfind("turn:", 0) == 0) {
        url = url.substr(5);
        s.turn = true;
        s.username = Str(srv, "username");
        s.password = Str(srv, "credential");
      } else {
        continue;
      }
      const auto q = url.find('?');
      if (q != std::string::npos) {
        if (url.find("transport=tcp", q) != std::string::npos) continue;
        url = url.substr(0, q);
      }
      const auto colon = url.rfind(':');
      if (colon != std::string::npos && url.find(']') == std::string::npos) {
        s.host = url.substr(0, colon);
        s.port = static_cast<uint16_t>(std::atoi(url.c_str() + colon + 1));
      } else {
        s.host = url;
      }
      if (s.host.empty() || s.port == 0) continue;
      out.push_back(std::move(s));
    }
  }
  return out;
}

void PeerConnection::HandleWelcome(const json& j) {
  peer_id_ = Str(j, "peer_id");
  ice_servers_ = ParseIceServers(j);
  connected_ = true;
  LOG_INFO("Signaling connected, peer_id=[{}], ice_servers={}", peer_id_,
           ice_servers_.size());
  if (params_.on_signal_status)
    params_.on_signal_status(MINIRTC_SIGNAL_CONNECTED, peer_id_.c_str(),
                             params_.user_data);
}

void PeerConnection::HandleError(const json& j) {
  const int64_t id = Int(j, "id", -1);
  const std::string code = Str(j, "code");
  const std::string message = Str(j, "message");
  Pending kind = Pending::kSignal;
  bool known = false;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    auto it = pending_.find(id);
    if (it != pending_.end()) {
      kind = it->second;
      known = true;
      pending_.erase(it);
    }
  }
  LOG_WARN("Signaling error id={} code=[{}] message=[{}]", id, code, message);
  if (!known) return;
  if (kind == Pending::kClaim) {
    MiniRtcClaimResult r = MINIRTC_CLAIM_ERROR;
    if (code == "code_not_found") r = MINIRTC_CLAIM_CODE_NOT_FOUND;
    else if (code == "code_expired") r = MINIRTC_CLAIM_CODE_EXPIRED;
    else if (code == "share_busy") r = MINIRTC_CLAIM_SHARE_BUSY;
    else if (code == "rate_limited") r = MINIRTC_CLAIM_RATE_LIMITED;
    NotifyClaim(r, "", "", message);
  } else if (kind == Pending::kCreateShare) {
    NotifyShare(MINIRTC_SHARE_FAILED, "", "", 0, code);
  }
}

// ---- shares ----------------------------------------------------------------

int PeerConnection::CreateShare(const std::string& mode, int ttl_sec,
                                const std::string& meta_json) {
  json msg = {{"type", "create_share"}, {"mode", mode.empty() ? "once" : mode}};
  if (ttl_sec > 0) msg["ttl_sec"] = ttl_sec;
  if (!meta_json.empty()) {
    try {
      msg["meta"] = json::parse(meta_json);
    } catch (...) {
      return -1;
    }
  }
  return SendRequest(msg, Pending::kCreateShare) > 0 ? 0 : -1;
}

int PeerConnection::CloseShare(const std::string& share_id) {
  json msg = {{"type", "close_share"}, {"share_id", share_id}};
  return SendRequest(msg, Pending::kCloseShare) > 0 ? 0 : -1;
}

void PeerConnection::HandleShareCreated(const json& j) {
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending_.erase(Int(j, "id", -1));
  }
  NotifyShare(MINIRTC_SHARE_CREATED, Str(j, "share_id"), Str(j, "code"),
              Int(j, "expires_at"), Str(j, "code_display"));
}

void PeerConnection::HandleShareClosed(const json& j) {
  NotifyShare(MINIRTC_SHARE_CLOSED, Str(j, "share_id"), "", 0, Str(j, "reason"));
}

void PeerConnection::NotifyShare(MiniRtcShareEvent ev, const std::string& share_id,
                                 const std::string& code, int64_t expires_at,
                                 const std::string& detail) {
  if (params_.on_share_event)
    params_.on_share_event(ev, share_id.c_str(), code.c_str(), expires_at,
                           detail.c_str(), params_.user_data);
}

void PeerConnection::NotifyClaim(MiniRtcClaimResult r, const std::string& sid,
                                 const std::string& token,
                                 const std::string& message) {
  if (params_.on_claim_result)
    params_.on_claim_result(r, sid.c_str(), token.c_str(), message.c_str(),
                            params_.user_data);
}

// ---- sessions ----------------------------------------------------------------

int PeerConnection::Claim(const std::string& code,
                          const std::string& resume_token) {
  json msg = {{"type", "claim"}};
  if (!resume_token.empty())
    msg["resume_token"] = resume_token;
  else
    msg["code"] = code;
  return SendRequest(msg, Pending::kClaim) > 0 ? 0 : -1;
}

int PeerConnection::Leave(const std::string& session_id) {
  auto s = FindSession(session_id);
  if (!s) return -1;
  EndSession(s, MINIRTC_SESSION_CLOSED, "local_leave", true);
  return 0;
}

PeerConnection::SessionPtr PeerConnection::FindSession(const std::string& id) const {
  std::shared_lock lock(sessions_mutex_);
  auto it = sessions_.find(id);
  return it == sessions_.end() ? nullptr : it->second;
}

void PeerConnection::HandleSessionStart(const json& j) {
  const std::string sid = Str(j, "session_id");
  if (sid.empty()) return;
  const int64_t req = Int(j, "id", -1);
  if (req > 0) {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending_.erase(req);
  }
  auto s = std::make_shared<Session>();
  s->id = sid;
  s->share_id = Str(j, "share_id");
  s->role = Str(j, "role");
  s->offerer = s->role == "receiver";
  s->remote_peer_id = Str(j, "remote_peer_id");
  s->resume_token = Str(j, "resume_token");
  if (j.contains("meta") && !j["meta"].is_null()) s->meta_json = j["meta"].dump();
  s->ice_servers = ParseIceServers(j);
  if (s->ice_servers.empty()) s->ice_servers = ice_servers_;
  s->created_ms = clock_->CurrentTimeMs();
  s->last_stats_ms = s->created_ms;
  s->relay_header.assign(kRelayHeaderSize, 0);
  s->relay_header[0] = 'C';
  s->relay_header[1] = 'R';
  s->relay_header[2] = 0x01;
  std::copy_n(sid.data(), std::min<size_t>(16, sid.size()), s->relay_header.begin() + 4);

  {
    std::unique_lock lock(sessions_mutex_);
    auto old = sessions_.find(sid);
    if (old != sessions_.end()) {
      // Resumed session on our side (sender, receiver came back): rebuild.
      auto prev = old->second;
      lock.unlock();
      EndSession(prev, MINIRTC_SESSION_CLOSED, "resumed", false);
      lock.lock();
    }
    sessions_[sid] = s;
  }
  const bool resumed = j.contains("resumed") && j["resumed"].is_boolean() &&
                       j["resumed"].get<bool>();
  LOG_INFO("session_start id=[{}] role=[{}] remote=[{}] resumed={}", sid,
           s->role, s->remote_peer_id, resumed ? "yes" : "no");
  if (s->role == "receiver") {
    NotifyClaim(MINIRTC_CLAIM_OK, sid, s->resume_token, "");
  } else {
    NotifyShare(MINIRTC_SHARE_CLAIMED, s->share_id, "", 0, sid);
  }
  NotifySession(*s, MINIRTC_SESSION_CONNECTING, "");
  StartSession(s);
}

void PeerConnection::StartSession(const SessionPtr& s) {
  std::weak_ptr<Session> weak = s;
  auto lock_session = [this, weak]() -> SessionPtr {
    auto sp = weak.lock();
    if (!sp) return nullptr;
    return FindSession(sp->id) == sp ? sp : nullptr;
  };

  s->data = std::make_shared<DataTransport>(
      clock_, streams_, params_.enable_srtp,
      [this, weak](const uint8_t* d, size_t n, const std::string& stream) {
        auto sp = weak.lock();
        if (!sp || !params_.on_receive_data) return;
        params_.on_receive_data(d, n, sp->id.c_str(), stream.c_str(),
                                params_.user_data);
      });
  s->data->Init();

  if (params_.enable_srtp) {
    s->dtls = std::make_unique<DtlsTransport>();
    s->dtls->SetDoneFunc([this, lock_session](bool ok) {
      Post([this, lock_session, ok]() {
        if (auto sp = lock_session()) OnDtlsDone(sp, ok);
      });
    });
  }

  IceConfig cfg;
  cfg.servers = s->ice_servers;
  cfg.turn_mode = params_.turn_mode;
  cfg.enable_upnp = params_.enable_upnp && params_.turn_mode != MINIRTC_TURN_FORCE;
  IceAgent::Callbacks cb;
  cb.on_state = [this, lock_session](IceState st) {
    Post([this, lock_session, st]() {
      if (auto sp = lock_session()) OnIceState(sp, st);
    });
  };
  cb.on_candidate = [this, lock_session](const std::string& line) {
    Post([this, lock_session, line]() {
      if (auto sp = lock_session()) OnIceCandidate(sp, line);
    });
  };
  cb.on_gathering_done = [this, lock_session]() {
    Post([this, lock_session]() {
      if (auto sp = lock_session()) OnIceGatheringDone(sp);
    });
  };
  // The ICE receive worker delivers outside libjuice's internal connection lock.
  cb.on_recv = [this, lock_session](const uint8_t* d, size_t n) {
    if (auto sp = lock_session()) OnPathDatagram(sp, d, n);
  };
  s->ice = std::make_unique<IceAgent>(cfg, std::move(cb));

  // Datagram sink: ICE while direct, WS relay after fallback.
  auto send_via_path = [this, weak](const uint8_t* d, size_t n) -> int {
    auto sp = weak.lock();
    if (!sp) return -1;
    if (Impairment().Active() && Impairment().Drop(n)) return 0;  // silently lost
    bool relay;
    {
      std::lock_guard<std::mutex> lock(sp->mutex);
      relay = sp->relay;
      if (sp->ended) return -1;
    }
    if (relay) {
      if (!ws_ || n + kRelayHeaderSize > 65536) return -1;
      std::vector<uint8_t> frame(sp->relay_header);
      frame.insert(frame.end(), d, d + n);
      return ws_->SendBinary(frame.data(), frame.size()) ? 0 : -1;
    }
    return sp->ice ? sp->ice->Send(d, n) : -1;
  };
  s->data->SetSendFunc(send_via_path);
  if (s->dtls) s->dtls->SetSendFunc(send_via_path);

  if (params_.force_ws_relay) {
    // Diagnostic / restrictive-network mode: never try ICE.
    if (s->offerer) SendLocalDescription(s, "offer");
    SwitchToRelay(s, "forced");
    return;
  }
  if (s->offerer) {
    SendLocalDescription(s, "offer");
    s->ice->GatherCandidates();
  }
  // The answerer gathers after the remote offer is applied so libjuice takes
  // the controlled role and only the offerer nominates.
}

void PeerConnection::SendLocalDescription(const SessionPtr& s, const char* kind) {
  std::ostringstream sdp;
  sdp << "v=0\r\n"
      << "o=- 0 0 IN IP4 0.0.0.0\r\n"
      << "s=-\r\n"
      << "t=0 0\r\n"
      << "m=application 9 UDP/DTLS/RTP/SAVPF 120 121\r\n"
      << "c=IN IP4 0.0.0.0\r\n"
      << "a=rtcp-mux\r\n"
      << "a=x-minirtc-version:1\r\n";
  sdp << s->ice->LocalDescription();
  if (s->dtls) {
    sdp << "a=fingerprint:sha-256 " << s->dtls->LocalFingerprint() << "\r\n";
    sdp << "a=setup:" << (s->offerer ? "actpass" : "active") << "\r\n";
  }
  sdp << s->data->LocalStreamSdpLines();
  {
    std::lock_guard<std::mutex> lock(s->mutex);
    s->local_description_sent = true;
  }
  SendSignal(*s, json{{"sdp", sdp.str()}, {"kind", kind}});
  LOG_INFO("[{}] sent {}", s->id, kind);
}

bool PeerConnection::ApplyRemoteDescription(const SessionPtr& s,
                                            const std::string& sdp) {
  if (s->dtls) {
    const std::string fp = ExtractFingerprint(sdp);
    if (fp.empty()) {
      LOG_ERROR("[{}] remote SDP lacks DTLS fingerprint", s->id);
      return false;
    }
    s->dtls->SetRemoteFingerprint(fp);
  }
  if (!s->data->ParseRemoteStreams(sdp)) return false;
  // libjuice ignores unknown lines; pass the whole SDP.
  if (s->ice->SetRemoteDescription(sdp) != 0) return false;
  std::vector<std::string> pending;
  bool gathering_done = false;
  {
    std::lock_guard<std::mutex> lock(s->mutex);
    s->remote_description_set = true;
    pending.swap(s->pending_remote_candidates);
    gathering_done = s->remote_gathering_done;
  }
  LOG_INFO("[{}] remote description applied, {} queued candidate(s), done={}",
           s->id, pending.size(), gathering_done);
  for (const auto& c : pending) {
    if (s->ice->AddRemoteCandidate(c) != 0)
      LOG_WARN("[{}] queued remote candidate rejected: {}", s->id, c);
  }
  if (gathering_done) s->ice->SetRemoteGatheringDone();
  if (!s->offerer && !params_.force_ws_relay) s->ice->GatherCandidates();
  return true;
}

void PeerConnection::SendSignal(const Session& s, json payload) {
  if (!ws_) return;
  json msg = {{"type", "signal"},
              {"session_id", s.id},
              {"to", s.remote_peer_id},
              {"payload", std::move(payload)}};
  std::lock_guard<std::mutex> lock(signal_mutex_);
  ws_->SendText(msg.dump());
}

void PeerConnection::HandleSignal(const json& j) {
  auto s = FindSession(Str(j, "session_id"));
  if (!s) return;
  auto payload = j.find("payload");
  if (payload == j.end() || !payload->is_object()) return;
  if (payload->contains("sdp")) {
    const std::string sdp = Str(*payload, "sdp");
    const std::string kind = Str(*payload, "kind");
    if (s->offerer && kind == "offer") {
      LOG_WARN("[{}] both sides offered; ignoring remote offer", s->id);
      return;
    }
    if (!ApplyRemoteDescription(s, sdp)) {
      EndSession(s, MINIRTC_SESSION_FAILED, "sdp_negotiation_failed", true);
      return;
    }
    if (!s->offerer) SendLocalDescription(s, "answer");
    return;
  }
  if (payload->contains("candidate")) {
    const std::string cand = Str(*payload, "candidate");
    bool apply = false;
    {
      std::lock_guard<std::mutex> lock(s->mutex);
      if (!s->remote_description_set) {
        if (s->pending_remote_candidates.size() < 256)
          s->pending_remote_candidates.push_back(cand);
      } else {
        apply = true;
      }
    }
    if (apply && s->ice->AddRemoteCandidate(cand) != 0)
      LOG_WARN("[{}] remote candidate rejected: {}", s->id, cand);
    LOG_DEBUG("[{}] remote candidate {}: {}", s->id, apply ? "applied" : "queued", cand);
    return;
  }
  if (payload->contains("candidates_done")) {
    bool apply = false;
    {
      std::lock_guard<std::mutex> lock(s->mutex);
      s->remote_gathering_done = true;
      apply = s->remote_description_set;
    }
    LOG_INFO("[{}] remote candidates done ({})", s->id, apply ? "applied" : "queued");
    if (apply) s->ice->SetRemoteGatheringDone();
    return;
  }
  if (payload->contains("relay")) {
    // Peer asks to fall back to the WS relay; agree if we allow it.
    if (params_.enable_ws_relay) SwitchToRelay(s, "peer_request");
    return;
  }
}

void PeerConnection::OnIceCandidate(const SessionPtr& s, const std::string& line) {
  LOG_INFO("[{}] local candidate: {}", s->id, line);
  SendSignal(*s, json{{"candidate", line}});
}

void PeerConnection::OnIceGatheringDone(const SessionPtr& s) {
  LOG_INFO("[{}] local gathering done", s->id);
  SendSignal(*s, json{{"candidates_done", true}});
}

void PeerConnection::OnIceState(const SessionPtr& s, IceState state) {
  LOG_INFO("[{}] ICE {}", s->id, IceStateName(state));
  switch (state) {
    case IceState::kConnected:
    case IceState::kCompleted: {
      bool first;
      {
        std::lock_guard<std::mutex> lock(s->mutex);
        if (s->relay) return;
        first = !s->path_ready;
        s->path_ready = true;
      }
      // Nomination may replace the initially connected candidate pair. Keep
      // the reported path and congestion profile in sync with the final pair.
      const bool relay = s->ice->SelectedPairUsesRelay();
      if (first || (s->data->Estimate().path == MINIRTC_PATH_TURN) != relay) {
        LOG_INFO("[{}] selected pair {} ({})", s->id,
                 s->ice->SelectedPairDescription(), relay ? "TURN" : "P2P");
        s->data->SetRelayPath(relay);
      }
      if (first) OnPathReady(s);
      break;
    }
    case IceState::kFailed: {
      bool relay_active;
      {
        std::lock_guard<std::mutex> lock(s->mutex);
        relay_active = s->relay;
      }
      if (relay_active) return;
      if (params_.enable_ws_relay) {
        SwitchToRelay(s, "ice_failed");
      } else {
        EndSession(s, MINIRTC_SESSION_FAILED, "ice_failed", true);
      }
      break;
    }
    default:
      break;
  }
}

void PeerConnection::SwitchToRelay(const SessionPtr& s, const char* why) {
  {
    std::lock_guard<std::mutex> lock(s->mutex);
    if (s->relay || s->ended) return;
    s->relay = true;
    s->path_ready = true;
    s->transport_ready = false;
  }
  LOG_WARN("[{}] falling back to WebSocket relay ({})", s->id, why);
  SendSignal(*s, json{{"relay", true}});
  if (s->dtls) s->dtls->Restart();
  s->data->SetTransportReady(false);
  s->data->SetRelayPath(true);
  OnPathReady(s);
}

void PeerConnection::OnPathReady(const SessionPtr& s) {
  if (s->dtls) {
    MaybeStartDtls(s);
  } else {
    {
      std::lock_guard<std::mutex> lock(s->mutex);
      s->transport_ready = true;
      s->status = MINIRTC_SESSION_CONNECTED;
    }
    s->data->SetTransportReady(true);
    NotifySession(*s, MINIRTC_SESSION_CONNECTED, "");
  }
}

void PeerConnection::MaybeStartDtls(const SessionPtr& s) {
  if (!s->dtls || s->dtls->Started()) return;
  if (!s->dtls->HasRemoteFingerprint()) {
    LOG_INFO("[{}] waiting for remote fingerprint before DTLS", s->id);
    return;
  }
  {
    std::lock_guard<std::mutex> lock(s->mutex);
    s->dtls_started_ms = clock_->CurrentTimeMs();
  }
  // The offerer (receiver) is the DTLS client.
  if (s->dtls->Start(s->offerer) != 0) {
    EndSessionAsync(s, MINIRTC_SESSION_FAILED, "dtls_failed", true);
  }
}

void PeerConnection::EndSessionAsync(const SessionPtr& s,
                                     MiniRtcSessionStatus status,
                                     const std::string& reason,
                                     bool notify_server) {
  Post([this, s, status, reason, notify_server]() {
    EndSession(s, status, reason, notify_server);
  });
}

void PeerConnection::OnDtlsDone(const SessionPtr& s, bool verified) {
  if (!verified) {
    EndSession(s, MINIRTC_SESSION_FAILED, "dtls_verify_failed", true);
    return;
  }
  std::vector<uint8_t> lk, ls, rk, rs;
  if (!s->dtls->ExportSrtpKeys(lk, ls, rk, rs) ||
      !s->data->SetSrtpKeys(lk, ls, rk, rs)) {
    EndSession(s, MINIRTC_SESSION_FAILED, "srtp_key_failed", true);
    return;
  }
  {
    std::lock_guard<std::mutex> lock(s->mutex);
    s->transport_ready = true;
    s->status = MINIRTC_SESSION_CONNECTED;
  }
  s->data->SetTransportReady(true);
  NotifySession(*s, MINIRTC_SESSION_CONNECTED, "");
}

void PeerConnection::OnPathDatagram(const SessionPtr& s, const uint8_t* data,
                                    size_t size) {
  if (s->dtls && DtlsTransport::IsDtlsRecord(data, size)) {
    if (!s->dtls->Started()) {
      bool ready;
      {
        std::lock_guard<std::mutex> lock(s->mutex);
        ready = s->path_ready;
      }
      // Before our own ICE pair is nominated we cannot send the reply flight;
      // the record is queued inside DtlsTransport until Start().
      if (ready) MaybeStartDtls(s);
    }
    s->dtls->HandleIncoming(data, size);
    return;
  }
  s->data->OnDatagram(data, size);
}

void PeerConnection::OnWsBinary(const uint8_t* data, size_t size) {
  if (size < kRelayHeaderSize || data[0] != 'C' || data[1] != 'R' || data[2] != 1)
    return;
  const std::string sid(reinterpret_cast<const char*>(data + 4), 16);
  auto s = FindSession(sid);
  if (!s) return;
  bool relay;
  {
    std::lock_guard<std::mutex> lock(s->mutex);
    relay = s->relay;
  }
  if (!relay) {
    // Remote already fell back; follow it (on the worker). The datagram is
    // still delivered: DTLS records are queued until the handshake starts.
    if (!params_.enable_ws_relay) return;
    Post([this, s]() { SwitchToRelay(s, "peer_relay_frame"); });
  }
  OnPathDatagram(s, data + kRelayHeaderSize, size - kRelayHeaderSize);
}

void PeerConnection::HandleSessionEnd(const json& j) {
  auto s = FindSession(Str(j, "session_id"));
  if (!s) return;
  const std::string reason = Str(j, "reason");
  const MiniRtcSessionStatus st =
      reason == "peer_offline" ? MINIRTC_SESSION_DISCONNECTED : MINIRTC_SESSION_CLOSED;
  EndSession(s, st, reason, false);
}

void PeerConnection::EndSession(const SessionPtr& s, MiniRtcSessionStatus status,
                                const std::string& reason, bool notify_server) {
  {
    std::lock_guard<std::mutex> lock(s->mutex);
    if (s->ended) return;
    s->ended = true;
    s->status = status;
  }
  {
    std::unique_lock lock(sessions_mutex_);
    auto it = sessions_.find(s->id);
    if (it != sessions_.end() && it->second == s) sessions_.erase(it);
  }
  if (notify_server && ws_ && connected_.load()) {
    json msg = {{"type", "leave"}, {"session_id", s->id}};
    SendRequest(msg, Pending::kLeave);
  }
  if (s->data) s->data->Destroy();
  if (s->ice) s->ice->Close();
  LOG_INFO("[{}] session ended: {}", s->id, reason);
  NotifySession(*s, status, reason);
}

void PeerConnection::EndAllSessions(const std::string& reason) {
  std::vector<SessionPtr> all;
  {
    std::shared_lock lock(sessions_mutex_);
    for (auto& [_, s] : sessions_) all.push_back(s);
  }
  for (auto& s : all) EndSession(s, MINIRTC_SESSION_CLOSED, reason, false);
}

void PeerConnection::NotifySession(const Session& s, MiniRtcSessionStatus status,
                                   const std::string& reason) {
  if (!params_.on_session_status) return;
  MiniRtcPath path = MINIRTC_PATH_UNKNOWN;
  if (s.relay) {
    path = MINIRTC_PATH_WS_RELAY;
  } else if (s.data) {
    path = s.data->Estimate().path;
  }
  params_.on_session_status(status, s.id.c_str(), s.role.c_str(),
                            s.resume_token.c_str(), s.meta_json.c_str(), path,
                            reason.c_str(), params_.user_data);
}

// ---- data --------------------------------------------------------------------

int PeerConnection::Send(const std::string& session_id, const std::string& stream,
                         const uint8_t* data, size_t size) {
  auto s = FindSession(session_id);
  if (!s || !s->data) return -1;
  return s->data->Send(stream, data, size);
}

int PeerConnection::GetLinkEstimate(const std::string& session_id,
                                    MiniRtcLinkEstimate* out) {
  auto s = FindSession(session_id);
  if (!s || !s->data || !out) return -1;
  *out = s->data->Estimate();
  bool relay;
  {
    std::lock_guard<std::mutex> lock(s->mutex);
    relay = s->relay;
  }
  if (relay) out->path = MINIRTC_PATH_WS_RELAY;
  return 0;
}

// ---- housekeeping -----------------------------------------------------------

bool PeerConnection::Process() {
  if (housekeeping_pending_.exchange(true)) return true;
  Post([this]() {
    Housekeeping();
    housekeeping_pending_ = false;
  });
  return true;
}

void PeerConnection::Housekeeping() {
  std::vector<SessionPtr> all;
  {
    std::shared_lock lock(sessions_mutex_);
    for (auto& [_, s] : sessions_) all.push_back(s);
  }
  const int64_t now = clock_->CurrentTimeMs();
  for (auto& s : all) {
    bool path_ready, transport_ready, relay;
    int64_t created, dtls_started, last_stats;
    {
      std::lock_guard<std::mutex> lock(s->mutex);
      if (s->ended) continue;
      path_ready = s->path_ready;
      transport_ready = s->transport_ready;
      relay = s->relay;
      created = s->created_ms;
      dtls_started = s->dtls_started_ms;
      last_stats = s->last_stats_ms;
    }
    if (!path_ready && !relay && now - created > params_.ice_timeout_ms) {
      if (params_.enable_ws_relay) {
        SwitchToRelay(s, "ice_timeout");
      } else {
        EndSession(s, MINIRTC_SESSION_FAILED, "ice_timeout", true);
      }
      continue;
    }
    if (s->dtls && path_ready && !transport_ready) {
      if (!s->dtls->Started()) {
        MaybeStartDtls(s);
      } else if (!s->dtls->Verified()) {
        s->dtls->HandleTimeout();
        if (dtls_started && now - dtls_started > kDtlsTimeoutMs) {
          EndSession(s, MINIRTC_SESSION_FAILED, "dtls_timeout", true);
          continue;
        }
      }
    }
    if (transport_ready && params_.on_net_stats && now - last_stats >= 1000) {
      {
        std::lock_guard<std::mutex> lock(s->mutex);
        s->last_stats_ms = now;
      }
      MiniRtcNetStats stats = s->data->TakeStats();
      if (relay) stats.link.path = MINIRTC_PATH_WS_RELAY;
      params_.on_net_stats(s->id.c_str(), &stats, params_.user_data);
    }
  }
}

}  // namespace minirtc
