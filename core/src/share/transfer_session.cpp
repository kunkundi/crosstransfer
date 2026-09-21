/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "share/transfer_session.h"

#include <algorithm>
#include <cstdint>

#include "log/log.h"
#include "transfer/path_sanitize.h"
#include "transfer/protocol.h"
#include "transfer/sha256.h"

namespace ct {

const char* TransferStateName(TransferState s) {
  switch (s) {
    case TransferState::kConnecting: return "connecting";
    case TransferState::kOffering: return "offering";
    case TransferState::kWaitingOffer: return "waiting_offer";
    case TransferState::kTransferring: return "transferring";
    case TransferState::kVerifying: return "verifying";
    case TransferState::kCompleted: return "completed";
    case TransferState::kFailed: return "failed";
    case TransferState::kCancelled: return "cancelled";
  }
  return "unknown";
}

namespace {
bool Terminal(TransferState s) {
  return s == TransferState::kCompleted || s == TransferState::kFailed ||
         s == TransferState::kCancelled;
}
}  // namespace

TransferSession::TransferSession(EventLoop* loop, std::shared_ptr<SessionLink> link,
                                 std::string transfer_id, std::string role, Callbacks cbs)
    : loop_(loop),
      link_(std::move(link)),
      transfer_id_(std::move(transfer_id)),
      session_id_(link_->session_id()),
      is_sender_(role == "sender"),
      cbs_(std::move(cbs)) {
  snap_.transfer_id = transfer_id_;
  snap_.session_id = session_id_;
  snap_.role = role;
  snap_.state = TransferState::kConnecting;
}

TransferSession::~TransferSession() {
  if (link_) link_->Detach();
  if (sender_) sender_->Stop();
  if (receiver_) receiver_->Stop();
}

void TransferSession::SetSenderInput(SenderInput input) {
  manifest_ = std::move(input.manifest);
  files_ = std::move(input.files);
  sender_file_ok_.assign(manifest_.files.size(), false);
  snap_.bytes_total = manifest_.total_bytes;
  snap_.files_total = static_cast<uint32_t>(manifest_.files.size());
}

void TransferSession::SetReceiverInput(ReceiverInput input) {
  save_dir_ = std::move(input.save_dir);
  resume_ = std::move(input.resume);
}

void TransferSession::SetState(TransferState s) {
  if (snap_.state == s || Terminal(snap_.state)) return;
  snap_.state = s;
  if (cbs_.on_state) cbs_.on_state(snap_);
}

void TransferSession::Fail(const std::string& code, const std::string& message) {
  if (Terminal(snap_.state)) return;
  CT_LOG_WARN("transfer {} failed: {} {}", transfer_id_, code, message);
  snap_.error_code = code;
  snap_.error_message = message;
  if (sender_) sender_->Stop();
  if (receiver_) receiver_->Stop();
  // Best-effort notify the peer (pointless when the session itself is gone).
  if (link_ && code != "session_end" && code != "peer_error") {
    link_->SendCtrl(nlohmann::json{{"type", "error"}, {"code", code}, {"msg", message}}.dump());
  }
  // The receiver keeps its resume record so the user can retry.
  SetState(TransferState::kFailed);
}

void TransferSession::SendCtrl(nlohmann::json msg) {
  if (link_) link_->SendCtrl(msg.dump());
}

void TransferSession::ScheduleProgress() {
  if (progress_scheduled_) return;
  progress_scheduled_ = true;
  std::weak_ptr<TransferSession> weak = weak_from_this();
  loop_->PostDelayed(
      [weak] {
        if (auto self = weak.lock()) {
          self->progress_scheduled_ = false;
          if (!Terminal(self->snap_.state)) self->EmitProgress(true);
        }
      },
      kProgressIntervalMs);
}

void TransferSession::EmitProgress(bool force) {
  if (is_sender_ && sender_) {
    const auto p = sender_->Progress();
    snap_.bytes_done = p.bytes_acked;
    snap_.files_done = p.files_done;
    snap_.rate_bps = p.send_rate_bps;
    snap_.current_file = p.current_file;
  } else if (receiver_) {
    const auto p = receiver_->Progress();
    snap_.bytes_done = p.bytes_received;
    snap_.files_done = p.files_done;
    snap_.rate_bps = p.recv_rate_bps;
    snap_.loss_permille = p.loss_permille;
    snap_.current_file = p.current_file;
  }
  if (force && cbs_.on_progress) cbs_.on_progress(snap_);
  if (!force) ScheduleProgress();
}

// ---- transport lifecycle ------------------------------------------------------

void TransferSession::OnTransportReady(MiniRtcPath path) {
  snap_.path = path;
  if (link_) link_->set_path(path);
  const bool first = !transport_ready_;
  transport_ready_ = true;
  if (!first) return;
  if (is_sender_) {
    StartOffer();
  } else {
    SetState(TransferState::kWaitingOffer);
  }
}

void TransferSession::OnTransportDown() {
  transport_ready_ = false;
  // Engines keep running; datagrams will fail until the path recovers. The
  // ctrl queue holds. No state change unless it never comes back (session_end).
}

void TransferSession::OnPathChanged(MiniRtcPath path) {
  snap_.path = path;
  if (link_) link_->set_path(path);
  EmitProgress(true);
}

void TransferSession::OnSessionEnd(const std::string& reason) {
  if (Terminal(snap_.state)) return;
  Fail("session_end", reason);
}

// ---- sender -------------------------------------------------------------------

void TransferSession::StartOffer() {
  if (offer_sent_ || files_.empty()) {
    if (files_.empty()) Fail("no_files", "nothing to send");
    return;
  }
  offer_sent_ = true;
  SetState(TransferState::kOffering);
  nlohmann::json msg = {{"type", "offer"}, {"manifest", manifest_.ToJson()}};
  SendCtrl(std::move(msg));
}

void TransferSession::HandleAccept(const nlohmann::json& j) {
  if (!is_sender_ || accept_received_) return;
  accept_received_ = true;
  std::map<uint16_t, std::vector<SackRun>> have;
  std::vector<uint16_t> verified;
  if (j.contains("files") && j["files"].is_array()) {
    for (const auto& f : j["files"]) {
      if (!f.contains("index") || !f["index"].is_number_unsigned()) continue;
      const uint16_t idx = f["index"].get<uint16_t>();
      if (idx >= manifest_.files.size()) continue;
      if (f.value("verified", false)) {
        verified.push_back(idx);
        continue;
      }
      if (f.contains("have") && f["have"].is_array()) {
        std::vector<SackRun> runs;
        for (const auto& r : f["have"]) {
          if (r.is_array() && r.size() == 2) runs.push_back({r[0].get<uint32_t>(), r[1].get<uint32_t>()});
        }
        if (!runs.empty()) have[idx] = std::move(runs);
      }
    }
  }
  SenderCallbacks scb;
  std::weak_ptr<TransferSession> weak = weak_from_this();
  EventLoop* loop = loop_;
  scb.on_file_done = [weak, loop](uint16_t index, const std::string& sha) {
    loop->Post([weak, index, sha] {
      if (auto self = weak.lock()) self->OnSenderFileDone(index, sha);
    });
  };
  scb.on_all_done = [weak, loop] {
    loop->Post([weak] {
      if (auto self = weak.lock()) self->OnSenderAllDone();
    });
  };
  scb.on_error = [weak, loop](const std::string& c, const std::string& m) {
    loop->Post([weak, c, m] {
      if (auto self = weak.lock()) self->Fail(c, m);
    });
  };
  sender_ = std::make_unique<SenderTransfer>(link_.get(), scb);
  SenderTransfer* sender = sender_.get();
  link_->SetSackHandler([sender](const uint8_t* d, size_t n) { sender->OnSack(d, n); });
  std::string err;
  if (!sender_->Start(manifest_, files_, have, verified, &err)) {
    Fail("start", err);
    return;
  }
  for (uint16_t v : verified) {
    if (v < sender_file_ok_.size()) sender_file_ok_[v] = true;
  }
  SetState(TransferState::kTransferring);
  EmitProgress(false);
}

void TransferSession::HandleFileAck(const nlohmann::json& j, bool ok) {
  if (!is_sender_ || !sender_) return;
  if (!j.contains("index") || !j["index"].is_number_unsigned()) return;
  const uint16_t idx = j["index"].get<uint16_t>();
  if (idx >= sender_file_ok_.size()) return;
  if (ok) {
    if (!sender_file_ok_[idx]) {
      sender_file_ok_[idx] = true;
      sender_->OnFileOk(idx);
    }
  } else {
    // Receiver discarded the file after a hash mismatch and will re-request
    // every block through SACK; forget what it claimed to have.
    CT_LOG_WARN("transfer {}: receiver rejected file {}, resending", transfer_id_, idx);
    sender_->OnFileBad(idx);
  }
}

void TransferSession::OnSenderFileDone(uint16_t index, const std::string& sha256) {
  SendCtrl({{"type", "file_done"}, {"index", index}, {"sha256", sha256}});
  EmitProgress(true);
}

void TransferSession::OnSenderAllDone() {
  if (done_sent_) return;
  done_sent_ = true;
  SendCtrl({{"type", "transfer_done"}});
  snap_.bytes_done = snap_.bytes_total;
  snap_.files_done = snap_.files_total;
  SetState(TransferState::kCompleted);
  EmitProgress(true);
}

// ---- receiver -----------------------------------------------------------------

std::string TransferSession::ManifestSignature() const {
  // Stable across runs of the same share: hash of the sorted file list.
  std::string blob;
  for (const auto& f : manifest_.files) blob += f.path + ":" + std::to_string(f.size) + "\n";
  return Sha256Hex(blob.data(), blob.size());
}

std::map<std::string, std::string> TransferSession::ChooseNames() {
  std::map<std::string, std::string> names;
  // Reuse persisted names on resume so we do not create a second copy.
  if (resume_.is_object() && resume_.contains("names") && resume_["names"].is_object()) {
    for (auto it = resume_["names"].begin(); it != resume_["names"].end(); ++it) {
      names[it.key()] = it.value().get<std::string>();
    }
  }
  for (const auto& r : manifest_.roots) {
    if (names.count(r.name)) continue;
    names[r.name] = paths::UniqueName(save_dir_, r.name, r.is_dir);
  }
  return names;
}

void TransferSession::HandleOffer(const nlohmann::json& j) {
  if (is_sender_ || receiver_) return;
  if (!j.contains("manifest")) {
    Fail("bad_offer", "missing manifest");
    return;
  }
  std::string err;
  if (!Manifest::FromJson(j["manifest"], &manifest_, &err)) {
    Fail("bad_offer", err);
    return;
  }
  if (save_dir_.empty()) {
    Fail("no_save_dir", "save directory not set");
    return;
  }
  snap_.bytes_total = manifest_.total_bytes;
  snap_.files_total = static_cast<uint32_t>(manifest_.files.size());

  // Resume only if the persisted record matches this manifest.
  std::vector<ReceiverFileState> resume_state;
  const std::string sig = ManifestSignature();
  if (resume_.is_object() && resume_.value("manifest_sig", "") == sig &&
      resume_.contains("files") && resume_["files"].is_array()) {
    for (const auto& f : resume_["files"]) {
      ReceiverFileState s;
      s.index = f.value("index", 0);
      s.verified = f.value("verified", false);
      if (f.contains("have") && f["have"].is_array()) {
        for (const auto& r : f["have"]) {
          if (r.is_array() && r.size() == 2) s.have.push_back({r[0].get<uint32_t>(), r[1].get<uint32_t>()});
        }
      }
      resume_state.push_back(std::move(s));
    }
  } else {
    resume_.clear();
  }
  names_ = ChooseNames();

  ReceiverCallbacks rcb;
  std::weak_ptr<TransferSession> weak = weak_from_this();
  EventLoop* loop = loop_;
  rcb.on_file_ok = [weak, loop](uint16_t index) {
    loop->Post([weak, index] {
      if (auto self = weak.lock()) {
        self->SendCtrl({{"type", "file_ok"}, {"index", index}});
        self->EmitProgress(true);
      }
    });
  };
  rcb.on_file_bad = [weak, loop](uint16_t index, const std::string& reason) {
    loop->Post([weak, index, reason] {
      if (auto self = weak.lock()) self->OnReceiverFileVerified(index, false, reason);
    });
  };
  rcb.on_all_done = [weak, loop] {
    loop->Post([weak] {
      if (auto self = weak.lock()) self->OnReceiverAllDone();
    });
  };
  rcb.on_error = [weak, loop](const std::string& c, const std::string& m) {
    loop->Post([weak, c, m] {
      if (auto self = weak.lock()) self->Fail(c, m);
    });
  };
  rcb.on_persist = [weak, loop](const std::vector<ReceiverFileState>& st) {
    loop->Post([weak, st] {
      if (auto self = weak.lock()) self->PersistReceiver(st);
    });
  };
  receiver_ = std::make_unique<ReceiverTransfer>(link_.get(), rcb);
  ReceiverTransfer* receiver = receiver_.get();
  link_->SetBlockHandler([receiver](const uint8_t* d, size_t n) { receiver->OnBlock(d, n); });
  if (!receiver_->Start(manifest_, save_dir_, names_, resume_state, &err)) {
    Fail("start", err);
    return;
  }

  // Reply accept with have-runs and already-verified files.
  nlohmann::json files = nlohmann::json::array();
  const auto have = receiver_->HaveRuns();
  const auto verified = receiver_->VerifiedFiles();
  std::set<uint16_t> vset(verified.begin(), verified.end());
  for (uint16_t v : verified) files.push_back({{"index", v}, {"verified", true}});
  for (const auto& [idx, runs] : have) {
    if (vset.count(idx)) continue;
    nlohmann::json jruns = nlohmann::json::array();
    for (const auto& r : runs) jruns.push_back({r.start, r.length});
    files.push_back({{"index", idx}, {"have", jruns}});
  }
  SendCtrl({{"type", "accept"}, {"files", files}});
  SetState(TransferState::kTransferring);
  EmitProgress(false);
}

void TransferSession::OnReceiverFileVerified(uint16_t index, bool ok, const std::string& reason) {
  if (!ok) {
    // The receiver reset the file and will re-request its blocks via SACK.
    // Tell the sender so a future version can re-offer; today it fails there.
    SendCtrl({{"type", "file_bad"}, {"index", index}, {"reason", reason}});
  }
}

void TransferSession::OnReceiverAllDone() {
  snap_.bytes_done = snap_.bytes_total;
  snap_.files_done = snap_.files_total;
  SetState(TransferState::kCompleted);
  if (cbs_.on_persist) cbs_.on_persist(nullptr);  // clear the resume record
  EmitProgress(true);
}

void TransferSession::PersistReceiver(const std::vector<ReceiverFileState>& state) {
  if (Terminal(snap_.state)) return;
  nlohmann::json files = nlohmann::json::array();
  for (const auto& s : state) {
    nlohmann::json have = nlohmann::json::array();
    for (const auto& r : s.have) have.push_back({r.start, r.length});
    files.push_back({{"index", s.index}, {"verified", s.verified}, {"have", have}});
  }
  nlohmann::json names = nlohmann::json::object();
  for (const auto& [root, name] : names_) names[root] = name;
  nlohmann::json record = {
      {"manifest_sig", ManifestSignature()},
      {"names", names},
      {"files", files},
  };
  if (cbs_.on_persist) cbs_.on_persist(record);
}

// ---- ctrl dispatch ------------------------------------------------------------

void TransferSession::OnCtrlMessage(const std::string& json) {
  nlohmann::json j;
  std::string type;
  if (!ParseCtrlMessage(json, &j, &type)) {
    CT_LOG_WARN("dropping malformed ctrl message on {}", transfer_id_);
    return;
  }
  if (type == "offer") {
    HandleOffer(j);
  } else if (type == "accept") {
    HandleAccept(j);
  } else if (type == "file_done") {
    if (!is_sender_ && receiver_ && j.contains("index") && j.contains("sha256")) {
      receiver_->OnFileDone(j["index"].get<uint16_t>(), j["sha256"].get<std::string>());
    }
  } else if (type == "file_ok") {
    HandleFileAck(j, true);
  } else if (type == "file_bad") {
    HandleFileAck(j, false);
  } else if (type == "transfer_done") {
    if (!is_sender_) {
      // Sender says everything was sent; our own all-done drives completion,
      // but if we are already complete this is a no-op.
      if (receiver_ && receiver_->Finished() && snap_.state != TransferState::kCompleted) {
        OnReceiverAllDone();
      }
    }
  } else if (type == "pause") {
    if (sender_) sender_->SetPaused(true);
  } else if (type == "resume") {
    if (sender_ && !paused_) sender_->SetPaused(false);
  } else if (type == "cancel") {
    if (!Terminal(snap_.state)) {
      snap_.error_code = "peer_cancelled";
      if (sender_) sender_->Stop();
      if (receiver_) receiver_->Stop();
      SetState(TransferState::kCancelled);
    }
  } else if (type == "error") {
    Fail("peer_error", j.value("code", std::string("error")));
  }
}

// ---- control ------------------------------------------------------------------

void TransferSession::Pause() {
  if (paused_ || Terminal(snap_.state)) return;
  paused_ = true;
  if (sender_) sender_->SetPaused(true);
  if (!is_sender_) SendCtrl({{"type", "pause"}});
}

void TransferSession::Resume() {
  if (!paused_ || Terminal(snap_.state)) return;
  paused_ = false;
  if (sender_) sender_->SetPaused(false);
  if (!is_sender_) SendCtrl({{"type", "resume"}});
}

void TransferSession::Cancel(const std::string& reason) {
  if (Terminal(snap_.state)) return;
  snap_.error_code = reason;
  if (link_) link_->SendCtrl(nlohmann::json{{"type", "cancel"}, {"reason", reason}}.dump());
  if (sender_) sender_->Stop();
  if (receiver_) {
    receiver_->Cleanup();
  }
  SetState(TransferState::kCancelled);
  if (!is_sender_ && cbs_.on_persist) cbs_.on_persist(nullptr);
}

}  // namespace ct
