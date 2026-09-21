/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "runtime/session_link.h"

#include "log/log.h"
#include "transfer/protocol.h"

namespace ct {
namespace {

constexpr int kCtrlRetryMs = 5;
constexpr int kCtrlUnavailableRetryMs = 50;
constexpr int kCtrlUnavailableTimeoutMs = 20000;

}  // namespace

SessionLink::SessionLink(EventLoop* loop, Peer* peer, std::string session_id)
    : loop_(loop), peer_(peer), session_id_(std::move(session_id)) {}

SessionLink::~SessionLink() { Detach(); }

void SessionLink::Attach() {
  if (attached_.exchange(true)) return;
  peer_->SetDataSink(session_id_, shared_from_this());
}

void SessionLink::Detach() {
  if (attached_.exchange(false)) peer_->RemoveDataSink(session_id_, this);
  std::unique_lock<std::shared_mutex> lock(handlers_mutex_);
  on_block_ = nullptr;
  on_sack_ = nullptr;
}

int SessionLink::SendDatagram(const char* stream, const uint8_t* data, size_t len) {
  if (!attached_.load()) return -1;
  return peer_->Send(session_id_, stream, data, len);
}

bool SessionLink::LinkEstimate(int64_t* bwe_bps, int* rtt_ms) {
  MiniRtcLinkEstimate est{};
  if (!peer_->GetLinkEstimate(session_id_, &est)) return false;
  *bwe_bps = est.bwe_bps;
  *rtt_ms = est.rtt_ms;
  return true;
}

void SessionLink::OnData(const std::string& stream, const uint8_t* data, size_t len) {
  std::shared_lock<std::shared_mutex> lock(handlers_mutex_);
  if (stream == kStreamData) {
    if (on_block_) on_block_(data, len);
  } else if (stream == kStreamSack) {
    if (on_sack_) on_sack_(data, len);
  }
}

void SessionLink::SetBlockHandler(DatagramHandler h) {
  std::unique_lock<std::shared_mutex> lock(handlers_mutex_);
  on_block_ = std::move(h);
}

void SessionLink::SetSackHandler(DatagramHandler h) {
  std::unique_lock<std::shared_mutex> lock(handlers_mutex_);
  on_sack_ = std::move(h);
}

void SessionLink::SendCtrl(const std::string& json, std::function<void()> on_fail) {
  for (auto& chunk : SplitCtrlMessage(json)) ctrl_queue_.push_back(std::move(chunk));
  if (on_fail) ctrl_fail_ = std::move(on_fail);
  if (!pump_scheduled_) {
    pump_scheduled_ = true;
    auto self = shared_from_this();
    loop_->Post([self] {
      self->pump_scheduled_ = false;
      self->Pump();
    });
  }
}

void SessionLink::Pump() {
  while (!ctrl_queue_.empty()) {
    if (!attached_.load()) {
      ctrl_queue_.clear();
      return;
    }
    const auto& chunk = ctrl_queue_.front();
    const int r = peer_->Send(session_id_, kStreamCtrl, chunk.data(), chunk.size());
    if (r == 0) {
      CT_LOG_DEBUG("ctrl chunk sent on {} ({} bytes, {} queued)", session_id_, chunk.size(),
                   ctrl_queue_.size() - 1);
      ctrl_queue_.pop_front();
      ctrl_unavailable_ms_ = 0;
      continue;
    }
    CT_LOG_DEBUG("ctrl send on {} returned {}", session_id_, r);
    int delay = kCtrlRetryMs;
    if (r < 0) {
      ctrl_unavailable_ms_ += kCtrlUnavailableRetryMs;
      if (ctrl_unavailable_ms_ >= kCtrlUnavailableTimeoutMs) {
        CT_LOG_WARN("ctrl send gave up on session {}", session_id_);
        ctrl_queue_.clear();
        ctrl_unavailable_ms_ = 0;
        if (ctrl_fail_) ctrl_fail_();
        return;
      }
      delay = kCtrlUnavailableRetryMs;
    }
    pump_scheduled_ = true;
    auto self = shared_from_this();
    loop_->PostDelayed(
        [self] {
          self->pump_scheduled_ = false;
          self->Pump();
        },
        delay);
    return;
  }
}

void SessionLink::OnCtrlChunk(const std::string& chunk,
                              const std::function<void(const std::string&)>& on_message) {
  std::string message, error;
  CT_LOG_DEBUG("ctrl chunk received on {} ({} bytes)", session_id_, chunk.size());
  if (reassembler_.Feed(reinterpret_cast<const uint8_t*>(chunk.data()), chunk.size(), &message,
                        &error)) {
    on_message(message);
  } else if (!error.empty()) {
    CT_LOG_WARN("ctrl chunk rejected on session {}: {}", session_id_, error);
  }
}

}  // namespace ct
