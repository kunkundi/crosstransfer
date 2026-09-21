/*
 * CrossTransfer core — per-session glue between Peer and the block engines.
 *
 * A SessionLink is bound to one MiniRTC session id. It implements BlockLink
 * for the engines (datagrams out), DataSink for the Peer (datagrams in), and
 * provides a ctrl-message send queue that respects KCP backpressure.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_RUNTIME_SESSION_LINK_H_
#define CT_RUNTIME_SESSION_LINK_H_

#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <shared_mutex>
#include <string>
#include <vector>

#include "runtime/event_loop.h"
#include "runtime/peer.h"
#include "transfer/ctrl_codec.h"
#include "transfer/sender.h"

namespace ct {

class SessionLink : public BlockLink,
                    public DataSink,
                    public std::enable_shared_from_this<SessionLink> {
 public:
  using DatagramHandler = std::function<void(const uint8_t*, size_t)>;

  SessionLink(EventLoop* loop, Peer* peer, std::string session_id);
  ~SessionLink() override;

  const std::string& session_id() const { return session_id_; }

  // Registers this link as the session's data sink.
  void Attach();
  // Unregisters the sink and drops handlers; further sends fail.
  void Detach();

  // BlockLink
  int SendDatagram(const char* stream, const uint8_t* data, size_t len) override;
  bool LinkEstimate(int64_t* bwe_bps, int* rtt_ms) override;

  // DataSink (MiniRTC thread)
  void OnData(const std::string& stream, const uint8_t* data, size_t len) override;

  // Any thread.
  void SetBlockHandler(DatagramHandler h);
  void SetSackHandler(DatagramHandler h);

  // Loop thread. Queues a ctrl JSON document; on_fail is invoked (loop
  // thread) if the transport stays unavailable for ~20 s.
  void SendCtrl(const std::string& json, std::function<void()> on_fail = {});
  // Loop thread. Feeds one raw ctrl chunk from the Peer; returns complete
  // messages through the callback.
  void OnCtrlChunk(const std::string& chunk,
                   const std::function<void(const std::string&)>& on_message);

  // Loop thread: ctrl chunks not yet accepted by the transport.
  size_t CtrlPending() const { return ctrl_queue_.size(); }

  MiniRtcPath path() const { return path_; }
  void set_path(MiniRtcPath p) { path_ = p; }

 private:
  void Pump();

  EventLoop* loop_;
  Peer* peer_;
  std::string session_id_;
  std::shared_mutex handlers_mutex_;
  DatagramHandler on_block_;
  DatagramHandler on_sack_;
  std::atomic<bool> attached_{false};
  MiniRtcPath path_ = MINIRTC_PATH_UNKNOWN;

  // ctrl queue (loop thread)
  std::deque<std::vector<uint8_t>> ctrl_queue_;
  std::function<void()> ctrl_fail_;
  bool pump_scheduled_ = false;
  int ctrl_unavailable_ms_ = 0;
  CtrlReassembler reassembler_;
};

}  // namespace ct

#endif  // CT_RUNTIME_SESSION_LINK_H_
