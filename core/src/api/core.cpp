/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "api/core.h"

#include <algorithm>
#include <chrono>
#include <random>
#include <thread>

#include "crosstransfer/ct_api.h"
#include "log/log.h"
#include "share/take_code.h"
#include "transfer/path_sanitize.h"

namespace ct {
namespace {

constexpr int kLingerMs = 1500;      // keep a finished session so ctrl flushes
constexpr int kShutdownDrainMs = 1500;

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

std::string RandomHex(size_t bytes) {
  static thread_local std::mt19937_64 rng{std::random_device{}()};
  static const char* kHex = "0123456789abcdef";
  std::string out;
  out.reserve(bytes * 2);
  for (size_t i = 0; i < bytes; ++i) {
    const auto v = static_cast<uint8_t>(rng());
    out.push_back(kHex[v >> 4]);
    out.push_back(kHex[v & 0xF]);
  }
  return out;
}

}  // namespace

// ---- construction -------------------------------------------------------------

std::unique_ptr<Core> Core::Create(const nlohmann::json& config, std::string* error) {
  Config cfg;
  std::string err;
  if (!cfg.Merge(config, &err)) {
    if (error) *error = err;
    return nullptr;
  }
  if (cfg.data_dir.empty()) {
    if (error) *error = "config.data_dir is required";
    return nullptr;
  }
  auto storage = std::make_unique<Storage>(paths::FromUtf8(cfg.data_dir));
  if (!storage->EnsureDataDir(&err)) {
    if (error) *error = "data_dir: " + err;
    return nullptr;
  }
  // Saved config underneath, caller's values on top.
  Config merged;
  merged.Merge(storage->LoadConfig(), nullptr);
  if (!merged.Merge(config, &err)) {
    if (error) *error = err;
    return nullptr;
  }
  if (merged.log_dir.empty()) merged.log_dir = paths::ToUtf8(storage->data_dir() / "logs");
  if (merged.save_dir.empty()) merged.save_dir = paths::ToUtf8(storage->data_dir() / "received");
  InitLog(merged.log_dir, merged.log_level);
  storage->SaveConfig(merged.ToJson(), nullptr);
  std::unique_ptr<Core> core(new Core(std::move(merged), std::move(storage)));
  core->Start();
  return core;
}

Core::Core(Config cfg, std::unique_ptr<Storage> storage)
    : cfg_(std::move(cfg)), storage_(std::move(storage)) {}

Core::~Core() { Shutdown(); }

void Core::Start() {
  loop_.Start();
  loop_.Post([this] {
    LoadReceives();
    std::string err;
    if (!cfg_.server_host.empty() && !EnsurePeer(&err)) {
      CT_LOG_ERROR("peer start failed: {}", err);
      Emit({{"type", "error"}, {"code", "peer"}, {"message", err}});
    }
  });
}

void Core::Shutdown() {
  if (!loop_.Running()) return;
  std::unique_ptr<Peer> peer;
  loop_.RunSync([&] {
    for (auto& [_, t] : transfers_) {
      if (t.session) t.session->Cancel("shutdown");
    }
  });
  // Let queued ctrl (file_ok / transfer_done / cancel) reach the peer.
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(kShutdownDrainMs);
  for (;;) {
    size_t pending = 0;
    loop_.RunSync([&] {
      for (auto& [_, t] : transfers_) {
        if (t.link) pending += t.link->CtrlPending();
      }
    });
    if (pending == 0 || std::chrono::steady_clock::now() >= deadline) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  std::this_thread::sleep_for(std::chrono::milliseconds(150));  // KCP ack round trip
  loop_.RunSync([&] {
    for (auto& [sid, t] : std::map<std::string, Transfer>(transfers_)) {
      if (peer_) peer_->Leave(sid);
      (void)t;
    }
    transfers_.clear();
    transfer_ids_.clear();
    SaveReceives();
    if (peer_) peer_->Close(true);
    peer = std::move(peer_);
  });
  loop_.Stop();
  peer.reset();
  std::lock_guard<std::mutex> lock(event_mutex_);
  event_fn_ = nullptr;
}

void Core::SetEventCallback(EventFn fn) {
  std::lock_guard<std::mutex> lock(event_mutex_);
  event_fn_ = std::move(fn);
}

void Core::Emit(nlohmann::json ev) {
  ev["ts"] = NowMs();
  EventFn fn;
  {
    std::lock_guard<std::mutex> lock(event_mutex_);
    fn = event_fn_;
  }
  if (fn) fn(ev.dump());
}

std::string Core::NewId(const char* prefix) { return std::string(prefix) + RandomHex(6); }

// ---- peer ---------------------------------------------------------------------

bool Core::EnsurePeer(std::string* error) {
  if (peer_) return true;
  if (cfg_.server_host.empty()) {
    if (error) *error = "server host not configured";
    return false;
  }
  Peer::Callbacks cbs;
  cbs.on_signal = [this](MiniRtcSignalStatus st, const std::string& pid) { OnSignal(st, pid); };
  cbs.on_share = [this](MiniRtcShareEvent ev, const std::string& sid, const std::string& code,
                        int64_t exp, const std::string& detail) {
    OnShareEvent(ev, sid, code, exp, detail);
  };
  cbs.on_claim = [this](MiniRtcClaimResult r, const std::string& sid, const std::string& tok,
                        const std::string& msg) { OnClaimResult(r, sid, tok, msg); };
  cbs.on_session = [this](const SessionInfo& info) { OnSession(info); };
  cbs.on_stats = [this](const std::string& sid, const MiniRtcNetStats& st) { OnStats(sid, st); };
  cbs.on_ctrl = [this](const std::string& sid, std::string data) { OnCtrl(sid, std::move(data)); };
  peer_ = std::make_unique<Peer>(&loop_, cfg_.ToPeerConfig(), std::move(cbs));
  if (!peer_->Connect(error)) {
    peer_.reset();
    return false;
  }
  return true;
}

void Core::RecreatePeer() {
  for (auto& [_, t] : transfers_) {
    if (t.session) t.session->OnSessionEnd("reconfigured");
  }
  transfers_.clear();
  transfer_ids_.clear();
  for (auto& [_, s] : shares_) {
    if (s.state != "completed" && s.state != "closed" && s.state != "failed") {
      CloseShareInternal(s, "closed", "reconfigured");
    }
  }
  if (peer_) peer_->Close(false);
  peer_.reset();
  signal_connected_ = false;
  std::string err;
  if (!EnsurePeer(&err)) Emit({{"type", "error"}, {"code", "peer"}, {"message", err}});
}

void Core::OnSignal(MiniRtcSignalStatus st, const std::string& peer_id) {
  peer_id_ = peer_id;
  const bool was = signal_connected_;
  signal_connected_ = st == MINIRTC_SIGNAL_CONNECTED;
  Emit({{"type", "signal_state"}, {"state", Peer::SignalStatusName(st)}, {"peer_id", peer_id}});
  if (signal_connected_ && !was) {
    PumpShareCreates();
    PumpClaims();
  }
  if (!signal_connected_ && was) {
    // MiniRTC ends every session on a signaling drop; shares are gone too.
    share_create_inflight_ = false;
    claim_inflight_ = false;
    for (auto& [_, s] : shares_) {
      if (s.state == "ready" || s.state == "claimed" || s.state == "transferring") {
        CloseShareInternal(s, "failed", "signal_lost");
      }
    }
    for (auto& [_, r] : receives_) {
      if (r.state == "claiming" || r.state == "connecting" || r.state == "waiting_offer") {
        FinishReceive(r, "failed", "signal_lost", "signaling connection lost");
      }
    }
  }
}

// ---- shares -------------------------------------------------------------------

int Core::ShareCreate(const std::vector<std::string>& paths, const nlohmann::json& options,
                      std::string* share_id, std::string* error) {
  if (paths.empty()) {
    if (error) *error = "no paths";
    return CT_ERR_INVALID_ARG;
  }
  std::string mode = cfg_.share_mode;
  int ttl = cfg_.share_ttl_sec;
  if (options.is_object()) {
    mode = options.value("mode", mode);
    ttl = options.value("ttl_sec", ttl);
  }
  if (mode != "once" && mode != "open") {
    if (error) *error = "mode must be once|open";
    return CT_ERR_INVALID_ARG;
  }
  const std::string id = NewId("sh_");
  if (share_id) *share_id = id;
  loop_.Post([this, id, paths, mode, ttl] {
    Share s;
    s.id = id;
    s.mode = mode;
    s.ttl_sec = ttl;
    s.paths = paths;
    std::string err;
    if (!BuildManifest(paths, &s.manifest, &s.files, &err)) {
      s.state = "failed";
      s.error = err;
      shares_[id] = s;
      EmitShare(shares_[id]);
      return;
    }
    shares_[id] = std::move(s);
    EmitShare(shares_[id]);
    if (!EnsurePeer(&err)) {
      shares_[id].state = "failed";
      shares_[id].error = err;
      EmitShare(shares_[id]);
      return;
    }
    share_create_queue_.push_back(id);
    PumpShareCreates();
  });
  return CT_OK;
}

void Core::PumpShareCreates() {
  if (share_create_inflight_ || !signal_connected_ || share_create_queue_.empty()) return;
  const std::string id = share_create_queue_.front();
  share_create_queue_.pop_front();
  auto it = shares_.find(id);
  if (it == shares_.end() || it->second.state != "creating") {
    PumpShareCreates();
    return;
  }
  DoShareCreate(id);
}

void Core::DoShareCreate(const std::string& id) {
  Share& s = shares_[id];
  nlohmann::json meta = {{"files", s.manifest.files.size()},
                         {"bytes", s.manifest.total_bytes},
                         {"name", s.manifest.roots.empty() ? "" : s.manifest.roots[0].name},
                         {"roots", s.manifest.roots.size()}};
  if (peer_->CreateShare(s.mode, s.ttl_sec, meta.dump()) != 0) {
    s.state = "failed";
    s.error = "create_share send failed";
    EmitShare(s);
    PumpShareCreates();
    return;
  }
  share_create_inflight_ = true;
}

Core::Share* Core::FindShareByServerId(const std::string& share_id) {
  for (auto& [_, s] : shares_) {
    if (s.share_id == share_id) return &s;
  }
  return nullptr;
}

Core::Share* Core::FindShareBySession(const std::string& session_id) {
  for (auto& [_, s] : shares_) {
    if (s.sessions.count(session_id)) return &s;
  }
  return nullptr;
}

void Core::OnShareEvent(MiniRtcShareEvent ev, const std::string& share_id, const std::string& code,
                        int64_t expires_at, const std::string& detail) {
  switch (ev) {
    case MINIRTC_SHARE_CREATED: {
      share_create_inflight_ = false;
      // Oldest "creating" share without a server id is the one this answers.
      Share* target = nullptr;
      for (auto& [_, s] : shares_) {
        if (s.state == "creating" && s.share_id.empty()) {
          target = &s;
          break;
        }
      }
      if (!target) {
        peer_->CloseShare(share_id);
        break;
      }
      target->share_id = share_id;
      target->code = takecode::Normalize(code);
      target->expires_at = expires_at;
      target->state = "ready";
      EmitShare(*target);
      PumpShareCreates();
      break;
    }
    case MINIRTC_SHARE_FAILED: {
      share_create_inflight_ = false;
      for (auto& [_, s] : shares_) {
        if (s.state == "creating" && s.share_id.empty()) {
          s.state = "failed";
          s.error = detail;
          EmitShare(s);
          break;
        }
      }
      PumpShareCreates();
      break;
    }
    case MINIRTC_SHARE_CLAIMED: {
      Share* s = FindShareByServerId(share_id);
      if (!s) break;
      s->receivers += 1;
      if (!detail.empty()) s->sessions[detail] = "";  // session id; transfer id follows
      if (s->state == "ready") s->state = "claimed";
      EmitShare(*s);
      break;
    }
    case MINIRTC_SHARE_CLOSED: {
      Share* s = FindShareByServerId(share_id);
      if (!s) break;
      if (s->state == "completed" || s->state == "closed" || s->state == "failed") break;
      // Transfers in flight keep going (server keeps the session); the code is
      // simply no longer claimable.
      if (s->sessions.empty()) {
        CloseShareInternal(*s, detail == "expired" || detail == "share_expired" ? "closed" : "closed",
                           detail);
      } else {
        s->error = detail;
        EmitShare(*s);
      }
      break;
    }
  }
}

void Core::EmitShare(const Share& s) {
  nlohmann::json ev = {
      {"type", "share_state"},
      {"id", s.id},
      {"share_id", s.share_id},
      {"state", s.state},
      {"mode", s.mode},
      {"code", s.code.empty() ? "" : takecode::Format(s.code)},
      {"link", cfg_.link_host.empty() ? takecode::MakeSchemeLink(s.code)
                                      : takecode::MakeHttpsLink(cfg_.link_host, s.code)},
      {"scheme_link", takecode::MakeSchemeLink(s.code)},
      {"expires_at", s.expires_at},
      {"files", s.manifest.files.size()},
      {"bytes", s.manifest.total_bytes},
      {"receivers", s.receivers},
      {"completed", s.completed},
      {"error", s.error},
  };
  Emit(std::move(ev));
}

void Core::CloseShareInternal(Share& s, const std::string& state, const std::string& reason) {
  if (s.state == "completed" || s.state == "closed" || s.state == "failed") return;
  if (!s.share_id.empty() && peer_ && signal_connected_) peer_->CloseShare(s.share_id);
  for (auto& [sid, tid] : std::map<std::string, std::string>(s.sessions)) {
    auto it = transfers_.find(sid);
    if (it != transfers_.end() && it->second.session) it->second.session->Cancel(reason);
  }
  s.state = state;
  s.error = reason;
  EmitShare(s);
}

int Core::ShareClose(const std::string& share_id) {
  loop_.Post([this, share_id] {
    auto it = shares_.find(share_id);
    if (it == shares_.end()) {
      Share* by_server = FindShareByServerId(share_id);
      if (!by_server) return;
      CloseShareInternal(*by_server, "closed", "user");
      return;
    }
    CloseShareInternal(it->second, "closed", "user");
  });
  return CT_OK;
}

// ---- receives -----------------------------------------------------------------

int Core::ReceiveStart(const std::string& code_or_link, const std::string& save_dir,
                       std::string* transfer_id, std::string* error) {
  const std::string code = takecode::ParseCodeOrLink(code_or_link);
  if (code.empty()) {
    if (error) *error = "invalid take-code";
    return CT_ERR_INVALID_ARG;
  }
  const std::string id = NewId("rx_");
  if (transfer_id) *transfer_id = id;
  const std::string dir = save_dir.empty() ? cfg_.save_dir : save_dir;
  loop_.Post([this, id, code, dir] {
    // Reuse an unfinished record for the same code so we resume instead of
    // downloading a second copy.
    for (auto& [tid, r] : receives_) {
      if (r.code == code && !r.active && r.state != "completed" && r.state != "cancelled") {
        Receive moved = r;
        receives_.erase(tid);
        moved.transfer_id = id;
        moved.save_dir = dir;
        moved.state = "claiming";
        moved.error_code.clear();
        moved.error_message.clear();
        receives_[id] = std::move(moved);
        StartClaim(receives_[id]);
        return;
      }
    }
    Receive r;
    r.transfer_id = id;
    r.code = code;
    r.save_dir = dir;
    r.created_at = NowMs();
    receives_[id] = std::move(r);
    StartClaim(receives_[id]);
  });
  return CT_OK;
}

int Core::ReceiveResume(const std::string& transfer_id) {
  loop_.Post([this, transfer_id] {
    auto it = receives_.find(transfer_id);
    if (it == receives_.end() || it->second.active) return;
    Receive& r = it->second;
    if (r.state == "completed" || r.state == "cancelled") return;
    r.state = "claiming";
    r.error_code.clear();
    r.error_message.clear();
    StartClaim(r);
  });
  return CT_OK;
}

void Core::StartClaim(Receive& r) {
  r.active = true;
  r.tried_token = false;
  EmitReceive(r);
  std::string err;
  if (!EnsurePeer(&err)) {
    FinishReceive(r, "failed", "peer", err);
    return;
  }
  claim_queue_.push_back(r.transfer_id);
  PumpClaims();
}

void Core::PumpClaims() {
  if (claim_inflight_ || !signal_connected_ || claim_queue_.empty()) return;
  const std::string id = claim_queue_.front();
  claim_queue_.pop_front();
  auto it = receives_.find(id);
  if (it == receives_.end() || it->second.state != "claiming") {
    PumpClaims();
    return;
  }
  Receive& r = it->second;
  int rc;
  if (!r.resume_token.empty() && !r.tried_token) {
    r.tried_token = true;
    rc = peer_->Claim("", r.resume_token);
  } else {
    rc = peer_->Claim(r.code, "");
  }
  if (rc != 0) {
    FinishReceive(r, "failed", "claim", "claim send failed");
    PumpClaims();
    return;
  }
  claim_inflight_ = true;
}

void Core::OnClaimResult(MiniRtcClaimResult res, const std::string& session_id,
                         const std::string& token, const std::string& message) {
  claim_inflight_ = false;
  // The oldest receive in "claiming" state owns this result.
  Receive* r = nullptr;
  for (auto& [_, rx] : receives_) {
    if (rx.state == "claiming" && rx.active) {
      if (!r || rx.created_at < r->created_at) r = &rx;
    }
  }
  if (!r) {
    PumpClaims();
    return;
  }
  if (res == MINIRTC_CLAIM_OK) {
    r->session_id = session_id;
    if (!token.empty()) r->resume_token = token;
    r->state = "connecting";
    EmitReceive(*r);
    SaveReceives();
  } else if (r->tried_token && (res == MINIRTC_CLAIM_CODE_NOT_FOUND || res == MINIRTC_CLAIM_SHARE_BUSY)) {
    // Resume token rejected (share expired or session taken); fall back to
    // the code once.
    CT_LOG_INFO("resume token rejected ({}), retrying with code", Peer::ClaimResultName(res));
    r->resume_token.clear();
    claim_queue_.push_front(r->transfer_id);
  } else {
    FinishReceive(*r, "failed", Peer::ClaimResultName(res), message);
  }
  PumpClaims();
}

Core::Receive* Core::FindReceiveBySession(const std::string& session_id) {
  for (auto& [_, r] : receives_) {
    if (r.session_id == session_id && r.active) return &r;
  }
  return nullptr;
}

void Core::EmitReceive(const Receive& r) {
  nlohmann::json ev = {
      {"type", "receive_state"},
      {"transfer_id", r.transfer_id},
      {"code", takecode::Format(r.code)},
      {"state", r.state},
      {"save_dir", r.save_dir},
      {"session_id", r.session_id},
      {"resumable", !r.resume_token.empty()},
      {"error_code", r.error_code},
      {"error_message", r.error_message},
  };
  if (!r.meta_json.empty()) {
    nlohmann::json meta = nlohmann::json::parse(r.meta_json, nullptr, false);
    if (!meta.is_discarded()) ev["meta"] = meta;
  }
  Emit(std::move(ev));
}

void Core::FinishReceive(Receive& r, const std::string& state, const std::string& code,
                         const std::string& message) {
  r.state = state;
  r.error_code = code;
  r.error_message = message;
  r.active = false;
  EmitReceive(r);
  SaveReceives();
}

void Core::SaveReceives() {
  nlohmann::json arr = nlohmann::json::array();
  for (const auto& [_, r] : receives_) {
    if (r.state == "completed" || r.state == "cancelled") continue;
    arr.push_back({{"transfer_id", r.transfer_id},
                   {"code", r.code},
                   {"save_dir", r.save_dir},
                   {"resume_token", r.resume_token},
                   {"state", r.state},
                   {"error_code", r.error_code},
                   {"created_at", r.created_at},
                   {"meta", r.meta_json},
                   {"record", r.record}});
  }
  std::string err;
  if (!storage_->SaveReceives(arr, &err)) CT_LOG_WARN("transfers.json save failed: {}", err);
}

void Core::LoadReceives() {
  for (const auto& j : storage_->LoadReceives()) {
    if (!j.is_object()) continue;
    Receive r;
    r.transfer_id = j.value("transfer_id", "");
    r.code = j.value("code", "");
    r.save_dir = j.value("save_dir", "");
    r.resume_token = j.value("resume_token", "");
    r.state = "interrupted";
    r.error_code = j.value("error_code", "");
    r.created_at = j.value("created_at", int64_t{0});
    r.meta_json = j.value("meta", "");
    if (j.contains("record")) r.record = j["record"];
    if (r.transfer_id.empty() || r.code.empty()) continue;
    receives_[r.transfer_id] = std::move(r);
  }
}

// ---- sessions -----------------------------------------------------------------

std::shared_ptr<TransferSession> Core::MakeSession(const std::string& session_id,
                                                   const std::string& role,
                                                   const std::string& transfer_id) {
  auto link = std::make_shared<SessionLink>(&loop_, peer_.get(), session_id);
  link->Attach();
  TransferSession::Callbacks cbs;
  cbs.on_state = [this](const TransferSnapshot& s) { OnTransferState(s); };
  cbs.on_progress = [this](const TransferSnapshot& s) { OnTransferProgress(s); };
  if (role == "receiver") {
    cbs.on_persist = [this, transfer_id](const nlohmann::json& record) {
      auto it = receives_.find(transfer_id);
      if (it == receives_.end()) return;
      it->second.record = record;
      const int64_t now = NowMs();
      if (record.is_null() || now - last_persist_ms_ > 1000) {
        last_persist_ms_ = now;
        SaveReceives();
      }
    };
  }
  auto session = std::make_shared<TransferSession>(&loop_, link, transfer_id, role, cbs);
  Transfer t;
  t.session = session;
  t.link = link;
  transfers_[session_id] = std::move(t);
  transfer_ids_[transfer_id] = session_id;
  return session;
}

void Core::DropTransfer(const std::string& session_id) {
  auto it = transfers_.find(session_id);
  if (it == transfers_.end()) return;
  if (it->second.session) transfer_ids_.erase(it->second.session->transfer_id());
  if (it->second.link) it->second.link->Detach();
  transfers_.erase(it);
}

void Core::OnSession(const SessionInfo& info) {
  auto existing = transfers_.find(info.session_id);
  switch (info.status) {
    case MINIRTC_SESSION_CONNECTING: {
      if (existing != transfers_.end()) {
        if (!existing->second.closing) break;  // duplicate notification
        DropTransfer(info.session_id);         // resumed: replace the finished one
      }
      if (info.role == "sender") {
        // share_claimed (which precedes this) recorded the session id.
        Share* s = FindShareBySession(info.session_id);
        if (!s) {
          for (auto& [_, sh] : shares_) {
            if (sh.state == "claimed" || sh.state == "transferring" || sh.state == "ready") {
              if (!s || sh.expires_at > s->expires_at) s = &sh;
            }
          }
        }
        if (!s) {
          CT_LOG_WARN("sender session {} without a share", info.session_id);
          peer_->Leave(info.session_id);
          break;
        }
        const std::string tid = NewId("tx_");
        s->sessions[info.session_id] = tid;
        s->state = "transferring";
        auto session = MakeSession(info.session_id, "sender", tid);
        transfers_[info.session_id].share_local_id = s->id;
        TransferSession::SenderInput in;
        in.manifest = s->manifest;
        in.files = s->files;
        session->SetSenderInput(std::move(in));
        EmitShare(*s);
      } else {
        Receive* r = FindReceiveBySession(info.session_id);
        if (!r) {
          // claim result may not have been processed yet (ordering is
          // claim -> session on the same loop, so this is defensive).
          for (auto& [_, rx] : receives_) {
            if (rx.state == "claiming" && rx.active) r = &rx;
          }
          if (r) r->session_id = info.session_id;
        }
        if (!r) {
          CT_LOG_WARN("receiver session {} without a receive", info.session_id);
          peer_->Leave(info.session_id);
          break;
        }
        if (!info.resume_token.empty()) r->resume_token = info.resume_token;
        if (!info.meta_json.empty()) r->meta_json = info.meta_json;
        r->state = "connecting";
        auto session = MakeSession(info.session_id, "receiver", r->transfer_id);
        transfers_[info.session_id].receive_id = r->transfer_id;
        TransferSession::ReceiverInput in;
        in.save_dir = paths::FromUtf8(r->save_dir);
        in.resume = r->record;
        session->SetReceiverInput(std::move(in));
        EmitReceive(*r);
        SaveReceives();
      }
      break;
    }
    case MINIRTC_SESSION_CONNECTED: {
      if (existing == transfers_.end()) break;
      existing->second.session->OnTransportReady(info.path);
      if (Receive* r = FindReceiveBySession(info.session_id)) {
        if (r->state == "connecting") {
          r->state = "waiting_offer";
          EmitReceive(*r);
        }
      }
      break;
    }
    case MINIRTC_SESSION_DISCONNECTED:
    case MINIRTC_SESSION_FAILED:
    case MINIRTC_SESSION_CLOSED: {
      if (existing == transfers_.end()) break;
      if (existing->second.closing) {
        // Already finished on our side; the peer left too, nothing to flush.
        DropTransfer(info.session_id);
        break;
      }
      // "resumed": the receiver came back through a new claim and a fresh
      // session with the same id follows; the new offer/accept round trip
      // carries the have-runs, so the old transfer is simply dropped.
      // Anything else (peer_left / peer_offline / ice_failed ...) ends it;
      // the receiver keeps its resume token and can claim again.
      existing->second.session->OnSessionEnd(info.reason);
      DropTransfer(info.session_id);
      break;
    }
  }
}

void Core::OnStats(const std::string& session_id, const MiniRtcNetStats& stats) {
  auto it = transfers_.find(session_id);
  if (it == transfers_.end() || !it->second.session) return;
  if (it->second.link && it->second.link->path() != stats.link.path &&
      stats.link.path != MINIRTC_PATH_UNKNOWN) {
    it->second.session->OnPathChanged(stats.link.path);
  }
}

void Core::OnCtrl(const std::string& session_id, std::string data) {
  auto it = transfers_.find(session_id);
  if (it == transfers_.end() || !it->second.session) return;
  auto session = it->second.session;
  it->second.link->OnCtrlChunk(data, [&](const std::string& msg) { session->OnCtrlMessage(msg); });
}

nlohmann::json Core::SnapshotJson(const TransferSnapshot& s) const {
  return {
      {"transfer_id", s.transfer_id},
      {"session_id", s.session_id},
      {"role", s.role},
      {"state", TransferStateName(s.state)},
      {"error_code", s.error_code},
      {"error_message", s.error_message},
      {"path", Peer::PathName(s.path)},
      {"bytes_total", s.bytes_total},
      {"bytes_done", s.bytes_done},
      {"files_total", s.files_total},
      {"files_done", s.files_done},
      {"rate_bps", s.rate_bps},
      {"loss_permille", s.loss_permille},
      {"current_file", s.current_file},
      {"eta_sec", s.rate_bps > 0 && s.bytes_total > s.bytes_done
                      ? static_cast<int64_t>((s.bytes_total - s.bytes_done) * 8 / s.rate_bps)
                      : -1},
  };
}

void Core::OnTransferState(const TransferSnapshot& snap) {
  nlohmann::json ev = SnapshotJson(snap);
  ev["type"] = "transfer_state";
  Emit(ev);
  auto it = transfers_.find(snap.session_id);
  const bool terminal = snap.state == TransferState::kCompleted ||
                        snap.state == TransferState::kFailed ||
                        snap.state == TransferState::kCancelled;
  if (snap.role == "sender") {
    if (it != transfers_.end()) {
      auto sit = shares_.find(it->second.share_local_id);
      if (sit != shares_.end()) {
        Share& s = sit->second;
        if (terminal) {
          s.sessions.erase(snap.session_id);
          if (snap.state == TransferState::kCompleted) s.completed += 1;
          if (s.mode == "once") {
            if (snap.state == TransferState::kCompleted) {
              s.state = "completed";
              if (peer_ && signal_connected_ && !s.share_id.empty()) peer_->CloseShare(s.share_id);
            } else if (s.state != "closed") {
              // Receiver may come back with its resume token; keep the share.
              s.state = "claimed";
              s.error = snap.error_code;
            }
          } else if (s.sessions.empty()) {
            s.state = "ready";
          }
          EmitShare(s);
        }
      }
    }
  } else {
    Receive* r = FindReceiveBySession(snap.session_id);
    if (r) {
      r->state = TransferStateName(snap.state);
      if (terminal) {
        r->error_code = snap.error_code;
        r->error_message = snap.error_message;
        r->active = false;
        if (snap.state == TransferState::kCompleted || snap.state == TransferState::kCancelled) {
          r->record = nullptr;
          r->resume_token.clear();
        }
      }
      EmitReceive(*r);
      if (terminal) SaveReceives();
    }
  }
  if (terminal && it != transfers_.end() && !it->second.closing) {
    it->second.closing = true;
    LingerThenDrop(snap.session_id, it->second.session);
  }
}

void Core::LingerThenDrop(const std::string& session_id,
                          std::weak_ptr<TransferSession> owner) {
  loop_.PostDelayed(
      [this, session_id, owner] {
        auto it = transfers_.find(session_id);
        // A resumed session reuses the id: only act on the transfer that
        // scheduled this linger.
        if (it == transfers_.end() || it->second.session != owner.lock()) return;
        if (it->second.link && it->second.link->CtrlPending() > 0 && signal_connected_) {
          LingerThenDrop(session_id, owner);  // still flushing; check again
          return;
        }
        if (peer_) peer_->Leave(session_id);
        DropTransfer(session_id);
      },
      kLingerMs);
}

void Core::OnTransferProgress(const TransferSnapshot& snap) {
  nlohmann::json ev = SnapshotJson(snap);
  ev["type"] = "transfer_progress";
  Emit(std::move(ev));
}

// ---- transfer control -------------------------------------------------------

int Core::TransferPause(const std::string& transfer_id) {
  loop_.Post([this, transfer_id] {
    auto it = transfer_ids_.find(transfer_id);
    if (it == transfer_ids_.end()) return;
    auto t = transfers_.find(it->second);
    if (t != transfers_.end() && t->second.session) t->second.session->Pause();
  });
  return CT_OK;
}

int Core::TransferResume(const std::string& transfer_id) {
  loop_.Post([this, transfer_id] {
    auto it = transfer_ids_.find(transfer_id);
    if (it == transfer_ids_.end()) return;
    auto t = transfers_.find(it->second);
    if (t != transfers_.end() && t->second.session) t->second.session->Resume();
  });
  return CT_OK;
}

int Core::TransferCancel(const std::string& transfer_id) {
  loop_.Post([this, transfer_id] {
    auto it = transfer_ids_.find(transfer_id);
    if (it != transfer_ids_.end()) {
      auto t = transfers_.find(it->second);
      if (t != transfers_.end() && t->second.session) t->second.session->Cancel("user");
      return;
    }
    // Not running: a pending / interrupted receive.
    auto r = receives_.find(transfer_id);
    if (r != receives_.end()) {
      claim_queue_.erase(std::remove(claim_queue_.begin(), claim_queue_.end(), transfer_id),
                         claim_queue_.end());
      r->second.record = nullptr;
      FinishReceive(r->second, "cancelled", "user", "");
    }
  });
  return CT_OK;
}

// ---- config / query -----------------------------------------------------------

int Core::UpdateConfig(const nlohmann::json& config, std::string* error) {
  Config next = cfg_;
  if (!next.Merge(config, error)) return CT_ERR_INVALID_ARG;
  loop_.Post([this, next] {
    const bool recreate = cfg_.PeerAffectingDiff(next);
    cfg_ = next;
    SetLogLevel(cfg_.log_level);
    storage_->SaveConfig(cfg_.ToJson(), nullptr);
    Emit({{"type", "config"}, {"config", cfg_.ToJson()}});
    if (recreate) RecreatePeer();
  });
  return CT_OK;
}

nlohmann::json Core::QueryLocked(const std::string& what) {
  nlohmann::json out = nlohmann::json::object();
  if (what == "shares" || what == "all") {
    nlohmann::json arr = nlohmann::json::array();
    for (const auto& [_, s] : shares_) {
      arr.push_back({{"id", s.id},
                     {"share_id", s.share_id},
                     {"state", s.state},
                     {"mode", s.mode},
                     {"code", s.code.empty() ? "" : takecode::Format(s.code)},
                     {"expires_at", s.expires_at},
                     {"files", s.manifest.files.size()},
                     {"bytes", s.manifest.total_bytes},
                     {"receivers", s.receivers},
                     {"completed", s.completed},
                     {"error", s.error}});
    }
    out["shares"] = arr;
  }
  if (what == "receives" || what == "all") {
    nlohmann::json arr = nlohmann::json::array();
    for (const auto& [_, r] : receives_) {
      arr.push_back({{"transfer_id", r.transfer_id},
                     {"code", takecode::Format(r.code)},
                     {"state", r.state},
                     {"save_dir", r.save_dir},
                     {"resumable", !r.resume_token.empty()},
                     {"error_code", r.error_code},
                     {"created_at", r.created_at}});
    }
    out["receives"] = arr;
  }
  if (what == "transfers" || what == "all") {
    nlohmann::json arr = nlohmann::json::array();
    for (const auto& [_, t] : transfers_) {
      if (t.session) arr.push_back(SnapshotJson(t.session->Snapshot()));
    }
    out["transfers"] = arr;
  }
  if (what == "config" || what == "all") {
    out["config"] = cfg_.ToJson();
    out["signal_connected"] = signal_connected_;
    out["peer_id"] = peer_id_;
  }
  return out;
}

std::string Core::Query(const std::string& what) {
  if (!loop_.Running()) return "{}";
  nlohmann::json out;
  if (loop_.IsCurrent()) {
    out = QueryLocked(what);
  } else {
    loop_.RunSync([&] { out = QueryLocked(what); });
  }
  return out.dump();
}

}  // namespace ct
