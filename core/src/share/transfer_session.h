/*
 * CrossTransfer core — file transfer session state machine.
 *
 * A TransferSession runs on top of one SessionLink and drives the ctrl
 * protocol for one paired session:
 *
 *   sender   : builds a Manifest, waits for the transport, sends `offer`,
 *              on `accept` starts a SenderTransfer, relays file_done, marks
 *              files ok on `file_ok`, sends `transfer_done`.
 *   receiver : on `offer` chooses final names, starts a ReceiverTransfer,
 *              replies `accept` with per-file have-runs, relays file_ok /
 *              file_bad, finishes on `transfer_done` (or its own all-done).
 *
 * All methods run on the core EventLoop. Progress and state changes are
 * reported through Callbacks (also on the loop).
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_SHARE_TRANSFER_SESSION_H_
#define CT_SHARE_TRANSFER_SESSION_H_

#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "runtime/event_loop.h"
#include "runtime/session_link.h"
#include "transfer/manifest.h"
#include "transfer/receiver.h"
#include "transfer/sender.h"

namespace ct {

enum class TransferState {
  kConnecting,     // transport not yet up
  kOffering,       // sender sent offer, waiting for accept
  kWaitingOffer,   // receiver waiting for offer
  kTransferring,
  kVerifying,      // receiver: last files being hashed
  kCompleted,
  kFailed,
  kCancelled,
};

const char* TransferStateName(TransferState s);

struct TransferSnapshot {
  std::string transfer_id;
  std::string session_id;
  std::string role;  // "sender" | "receiver"
  TransferState state = TransferState::kConnecting;
  std::string error_code;
  std::string error_message;
  MiniRtcPath path = MINIRTC_PATH_UNKNOWN;
  uint64_t bytes_total = 0;
  uint64_t bytes_done = 0;   // acked (sender) or received (receiver)
  uint32_t files_total = 0;
  uint32_t files_done = 0;
  int64_t rate_bps = 0;
  uint16_t loss_permille = 0;
  int32_t current_file = -1;
};

class TransferSession : public std::enable_shared_from_this<TransferSession> {
 public:
  struct SenderInput {
    Manifest manifest;
    std::vector<std::filesystem::path> files;
  };
  struct ReceiverInput {
    std::filesystem::path save_dir;
    // Resume records keyed by manifest signature; may be empty.
    nlohmann::json resume;  // {"manifest_sig":..,"names":{root:name},"files":[{index,have,verified}]}
  };
  struct Callbacks {
    std::function<void(const TransferSnapshot&)> on_state;    // state transitions
    std::function<void(const TransferSnapshot&)> on_progress; // throttled
    // Receiver persistence: store `record` under the transfer id (or clear it
    // when `record` is null on completion / cancel).
    std::function<void(const nlohmann::json& record)> on_persist;
  };

  TransferSession(EventLoop* loop, std::shared_ptr<SessionLink> link, std::string transfer_id,
                  std::string role, Callbacks cbs);
  ~TransferSession();

  const std::string& transfer_id() const { return transfer_id_; }
  const std::string& session_id() const { return session_id_; }

  // Sender only: provide the built manifest + absolute file paths.
  void SetSenderInput(SenderInput input);
  // Receiver only: save dir + optional resume record.
  void SetReceiverInput(ReceiverInput input);

  // Transport up: begin the ctrl exchange. `path` is the observed path.
  void OnTransportReady(MiniRtcPath path);
  // Transport lost (may recover). Engines keep their state; ctrl resumes.
  void OnTransportDown();
  void OnPathChanged(MiniRtcPath path);
  // One reassembled ctrl JSON document.
  void OnCtrlMessage(const std::string& json);

  void Pause();
  void Resume();
  void Cancel(const std::string& reason);
  // Peer/session ended by signaling.
  void OnSessionEnd(const std::string& reason);

  TransferSnapshot Snapshot() const { return snap_; }
  TransferState state() const { return snap_.state; }

 private:
  void SetState(TransferState s);
  void EmitProgress(bool force);
  void ScheduleProgress();
  void Fail(const std::string& code, const std::string& message);
  void SendCtrl(nlohmann::json msg);

  // sender
  void StartOffer();
  void HandleAccept(const nlohmann::json& j);
  void HandleFileAck(const nlohmann::json& j, bool ok);
  void OnSenderFileDone(uint16_t index, const std::string& sha256);
  void OnSenderAllDone();

  // receiver
  void HandleOffer(const nlohmann::json& j);
  void OnReceiverFileVerified(uint16_t index, bool ok, const std::string& reason);
  void OnReceiverAllDone();
  void PersistReceiver(const std::vector<ReceiverFileState>& state);
  std::string ManifestSignature() const;
  std::map<std::string, std::string> ChooseNames();

  EventLoop* loop_;
  std::shared_ptr<SessionLink> link_;
  std::string transfer_id_;
  std::string session_id_;
  bool is_sender_ = false;
  Callbacks cbs_;
  TransferSnapshot snap_;

  bool transport_ready_ = false;
  bool offer_sent_ = false;
  bool accept_received_ = false;
  bool paused_ = false;
  bool progress_scheduled_ = false;
  bool done_sent_ = false;

  Manifest manifest_;
  std::vector<std::filesystem::path> files_;
  std::unique_ptr<SenderTransfer> sender_;
  std::vector<bool> sender_file_ok_;

  std::filesystem::path save_dir_;
  nlohmann::json resume_;
  std::map<std::string, std::string> names_;
  std::unique_ptr<ReceiverTransfer> receiver_;
};

}  // namespace ct

#endif  // CT_SHARE_TRANSFER_SESSION_H_
