/*
 * CrossTransfer core — the core object behind the C API.
 *
 * Owns the EventLoop, Storage, Config, the signaling Peer and every Share /
 * Receive. Public methods are callable from any thread and never block on
 * the network; they post to the loop. Events are emitted as JSON strings.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_API_CORE_H_
#define CT_API_CORE_H_

#include <cstdint>
#include <deque>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "api/config.h"
#include "runtime/event_loop.h"
#include "runtime/peer.h"
#include "share/transfer_session.h"
#include "storage/storage.h"

namespace ct {

class Core {
 public:
  using EventFn = std::function<void(const std::string& json)>;

  // `error` is set and nullptr returned when the data dir is unusable.
  static std::unique_ptr<Core> Create(const nlohmann::json& config, std::string* error);
  ~Core();

  void SetEventCallback(EventFn fn);
  int UpdateConfig(const nlohmann::json& config, std::string* error);

  int ShareCreate(const std::vector<std::string>& paths, const nlohmann::json& options,
                  std::string* share_id, std::string* error);
  int ShareClose(const std::string& share_id);

  int ReceiveStart(const std::string& code_or_link, const std::string& save_dir,
                   std::string* transfer_id, std::string* error);
  int ReceiveResume(const std::string& transfer_id);

  int TransferPause(const std::string& transfer_id);
  int TransferResume(const std::string& transfer_id);
  int TransferCancel(const std::string& transfer_id);

  std::string Query(const std::string& what);

 private:
  struct Share {
    std::string id;         // local id returned by ShareCreate
    std::string share_id;   // server id (after share_created)
    std::string code;       // canonical
    int64_t expires_at = 0;
    std::string mode;
    int ttl_sec = 0;
    std::string state = "creating";  // creating|ready|claimed|transferring|completed|closed|failed
    std::string error;
    std::vector<std::string> paths;
    Manifest manifest;
    std::vector<std::filesystem::path> files;
    std::map<std::string, std::string> sessions;  // session_id -> transfer_id
    int receivers = 0;
    int completed = 0;
  };
  struct Receive {
    std::string transfer_id;
    std::string code;  // canonical
    std::string save_dir;
    std::string resume_token;
    std::string session_id;
    std::string state = "claiming";  // claiming|connecting|waiting_offer|transferring|verifying|completed|failed|cancelled
    std::string error_code, error_message;
    std::string meta_json;
    nlohmann::json record;  // receiver resume record
    int64_t created_at = 0;
    bool tried_token = false;
    bool active = false;  // has an in-flight claim or session
  };
  struct Transfer {
    std::shared_ptr<TransferSession> session;
    std::shared_ptr<SessionLink> link;
    std::string share_local_id;  // sender side
    std::string receive_id;      // receiver side
    bool closing = false;        // terminal; lingering so ctrl can flush
  };

  Core(Config cfg, std::unique_ptr<Storage> storage);
  void Start();
  void Shutdown();
  void Emit(nlohmann::json ev);

  // loop thread
  bool EnsurePeer(std::string* error);
  void RecreatePeer();
  void OnSignal(MiniRtcSignalStatus st, const std::string& peer_id);
  void OnShareEvent(MiniRtcShareEvent ev, const std::string& share_id, const std::string& code,
                    int64_t expires_at, const std::string& detail);
  void OnClaimResult(MiniRtcClaimResult r, const std::string& session_id,
                     const std::string& token, const std::string& message);
  void OnSession(const SessionInfo& info);
  void OnStats(const std::string& session_id, const MiniRtcNetStats& stats);
  void OnCtrl(const std::string& session_id, std::string data);

  void DoShareCreate(const std::string& id);
  void PumpShareCreates();
  Share* FindShareByServerId(const std::string& share_id);
  Share* FindShareBySession(const std::string& session_id);
  void EmitShare(const Share& s);
  void CloseShareInternal(Share& s, const std::string& state, const std::string& reason);

  void StartClaim(Receive& r);
  void PumpClaims();
  Receive* FindReceiveBySession(const std::string& session_id);
  void EmitReceive(const Receive& r);
  void FinishReceive(Receive& r, const std::string& state, const std::string& code,
                     const std::string& message);
  void SaveReceives();
  void LoadReceives();

  std::shared_ptr<TransferSession> MakeSession(const std::string& session_id,
                                               const std::string& role,
                                               const std::string& transfer_id);
  void DropTransfer(const std::string& session_id);
  void LingerThenDrop(const std::string& session_id,
                      std::weak_ptr<TransferSession> owner);
  void OnTransferState(const TransferSnapshot& snap);
  void OnTransferProgress(const TransferSnapshot& snap);
  nlohmann::json SnapshotJson(const TransferSnapshot& s) const;
  nlohmann::json QueryLocked(const std::string& what);

  std::string NewId(const char* prefix);

  Config cfg_;
  std::unique_ptr<Storage> storage_;
  EventLoop loop_{"ct-core"};
  std::mutex event_mutex_;
  EventFn event_fn_;
  std::unique_ptr<Peer> peer_;
  std::string peer_id_;
  bool signal_connected_ = false;
  nlohmann::json notifications_ = nullptr; // null until first server snapshot

  std::map<std::string, Share> shares_;              // by local id
  std::deque<std::string> share_create_queue_;       // local ids awaiting share_created
  bool share_create_inflight_ = false;
  std::map<std::string, Receive> receives_;          // by transfer id
  std::deque<std::string> claim_queue_;              // transfer ids awaiting claim result
  bool claim_inflight_ = false;
  std::map<std::string, Transfer> transfers_;        // by session id
  std::map<std::string, std::string> transfer_ids_;  // transfer id -> session id
  int64_t last_persist_ms_ = 0;
};

}  // namespace ct

#endif  // CT_API_CORE_H_
