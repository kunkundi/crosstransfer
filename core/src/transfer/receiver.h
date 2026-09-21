/*
 * CrossTransfer core — block protocol receiver.
 *
 * One ReceiverTransfer per session. Incoming blocks (transport thread) are
 * queued to a writer thread that pwrite()s them into <name>.ctpart files and
 * marks the bitmap. A timer on the writer thread emits SACKs for files with
 * activity; when a file's bitmap completes it is verified (SHA-256 against
 * the sender's file_done hash) and renamed into place. Bitmaps are
 * persisted periodically through the on_persist callback so a killed
 * process can resume.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_TRANSFER_RECEIVER_H_
#define CT_TRANSFER_RECEIVER_H_

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

#include "transfer/bitmap.h"
#include "transfer/block_codec.h"
#include "transfer/file_io.h"
#include "transfer/manifest.h"
#include "transfer/sender.h"  // BlockLink

namespace ct {

struct ReceiverProgress {
  uint64_t bytes_total = 0;
  uint64_t bytes_received = 0;  // distinct payload bytes on disk
  uint32_t files_total = 0;
  uint32_t files_done = 0;      // verified and renamed
  int32_t current_file = -1;    // last file that received data
  int64_t recv_rate_bps = 0;
  uint16_t loss_permille = 0;
  uint32_t duplicates = 0;
};

// Per-file persistent state (resume).
struct ReceiverFileState {
  uint16_t index = 0;
  std::vector<SackRun> have;  // received runs
  bool verified = false;
};

struct ReceiverCallbacks {
  // Invoked on the writer thread; the owner marshals to its loop.
  std::function<void(uint16_t index)> on_file_ok;
  std::function<void(uint16_t index, const std::string& reason)> on_file_bad;
  std::function<void()> on_all_done;
  std::function<void(const std::string& code, const std::string& message)> on_error;
  // Called at most every persist_interval with the current state.
  std::function<void(const std::vector<ReceiverFileState>&)> on_persist;
};

class ReceiverTransfer {
 public:
  ReceiverTransfer(BlockLink* link, ReceiverCallbacks cbs);
  ~ReceiverTransfer();
  ReceiverTransfer(const ReceiverTransfer&) = delete;
  ReceiverTransfer& operator=(const ReceiverTransfer&) = delete;

  // Prepares directories, .ctpart files and bitmaps; `resume` carries the
  // state saved by on_persist (may be empty). Starts the writer thread.
  // `final_names` maps each manifest root to the (possibly de-duplicated)
  // name it gets under save_dir; the caller decides these once and persists
  // them alongside the transfer.
  bool Start(const Manifest& manifest, const std::filesystem::path& save_dir,
             const std::map<std::string, std::string>& final_names,
             const std::vector<ReceiverFileState>& resume, std::string* error);

  // Runs of blocks already held per file (for `accept`).
  std::map<uint16_t, std::vector<SackRun>> HaveRuns() const;
  std::vector<uint16_t> VerifiedFiles() const;

  // Transport thread.
  void OnBlock(const uint8_t* data, size_t len);
  // Owner thread: the sender finished sweeping this file and reports its hash.
  void OnFileDone(uint16_t index, const std::string& sha256);

  void Stop();  // joins the writer thread; leaves .ctpart files in place
  // Deletes .ctpart files and any created empty dirs of unfinished roots.
  void Cleanup();
  bool Finished() const { return finished_.load(); }

  ReceiverProgress Progress() const;
  std::vector<ReceiverFileState> Snapshot() const;

 private:
  struct FileRx {
    uint16_t index = 0;
    uint64_t size = 0;
    uint32_t blocks = 0;
    std::filesystem::path part_path;
    std::filesystem::path final_path;
    BlockBitmap bitmap;
    std::unique_ptr<FileWriter> writer;
    std::string expected_sha256;  // from file_done
    bool complete = false;        // bitmap full
    bool verified = false;
    bool verifying = false;
    bool dirty = false;           // SACK due
    uint32_t last_sack_ms = 0;
    uint32_t received_since_sack = 0;
    uint32_t expected_since_sack = 0;
    uint32_t frontier = 0;
    uint32_t complete_sacks_sent = 0;
  };

  struct Pending {
    uint16_t file;
    uint32_t block;
    uint16_t len;
    std::vector<uint8_t> payload;
  };

  void Run();
  void HandleBatch(std::deque<Pending>& batch, uint32_t now);
  // Validates one block; returns true if it is new and should be written.
  bool AcceptBlock(const Pending& p);
  bool FlushRun(FileRx& f, uint32_t first_block, const std::vector<uint8_t>& data,
                const std::vector<uint32_t>& blocks, uint32_t now);
  void SendSacks(uint32_t now, bool force);
  void SendSack(FileRx& f, uint32_t now);
  void MaybeVerify(FileRx& f);
  void Persist(bool force);
  void UpdateRates(uint32_t now);
  uint32_t NowMs() const;
  void Fail(const std::string& code, const std::string& message);
  bool AllVerified() const;

  BlockLink* link_;
  ReceiverCallbacks cbs_;
  Manifest manifest_;
  std::filesystem::path save_dir_;
  std::vector<std::unique_ptr<FileRx>> rx_;
  std::vector<std::filesystem::path> created_dirs_;

  std::thread thread_;
  std::atomic<bool> stop_{false};
  std::atomic<bool> finished_{false};
  std::atomic<bool> failed_{false};
  std::chrono::steady_clock::time_point start_;

  // Queue transport -> writer.
  std::mutex queue_mutex_;
  std::condition_variable queue_cv_;
  std::deque<Pending> queue_;
  size_t queue_bytes_ = 0;
  static constexpr size_t kMaxQueueBytes = 64u * 1024u * 1024u;

  // Owner -> writer messages, also guarded by queue_mutex_ so the wake
  // predicate and both producer queues have the same synchronization.
  std::map<uint16_t, std::string> pending_done_;

  mutable std::mutex state_mutex_;  // guards rx_ bitmaps for snapshots
  uint32_t last_persist_ms_ = 0;
  uint32_t last_rate_ms_ = 0;
  uint64_t rate_bytes_ = 0;
  uint32_t rate_expected_ = 0;
  uint32_t rate_received_ = 0;

  std::atomic<uint64_t> bytes_received_{0};
  std::atomic<uint32_t> files_done_{0};
  std::atomic<int32_t> current_file_{-1};
  std::atomic<int64_t> recv_rate_bps_{0};
  std::atomic<uint16_t> loss_permille_{0};
  std::atomic<uint32_t> duplicates_{0};
};

}  // namespace ct

#endif  // CT_TRANSFER_RECEIVER_H_
