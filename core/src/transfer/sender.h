/*
 * CrossTransfer core — block protocol sender (Sweep / Repair).
 *
 * One SenderTransfer drives one session: files are sent in manifest order.
 * Sweep sends every block of a file once (skipping blocks the receiver
 * reported in `accept`), hashing the file on the way. A swept file stays
 * "in flight" until the owner reports the receiver's `file_ok`; meanwhile
 * holes from SACKs (and the implicit tail beyond the receiver's frontier)
 * are resent no sooner than a hold time derived from RTT. Up to
 * kMaxInflightFiles files may await completion while the sweep continues
 * with the next file, so many small files do not serialise on SACK cadence.
 *
 * Rate: the link's BWE when known, capped by an AIMD estimate fed by the
 * receiver's loss reports; link backpressure (return 1) always wins.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_TRANSFER_SENDER_H_
#define CT_TRANSFER_SENDER_H_

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "transfer/bitmap.h"
#include "transfer/block_codec.h"
#include "transfer/file_io.h"
#include "transfer/manifest.h"

namespace ct {

// Datagram path used by both engines. Implemented by the session objects on
// top of Peer, and by an in-memory pipe in tests.
class BlockLink {
 public:
  virtual ~BlockLink() = default;
  // 0 ok, 1 backpressure (retry later), -1 error (transport not ready).
  virtual int SendDatagram(const char* stream, const uint8_t* data, size_t len) = 0;
  // Returns false when no estimate is available. bwe_bps may be 0.
  virtual bool LinkEstimate(int64_t* bwe_bps, int* rtt_ms) = 0;
};

struct SenderProgress {
  uint64_t bytes_total = 0;
  uint64_t bytes_sent = 0;    // payload bytes handed to the link (incl. repairs)
  uint64_t bytes_acked = 0;   // payload bytes the receiver has confirmed
  uint32_t files_total = 0;
  uint32_t files_done = 0;    // file_ok received
  int32_t current_file = -1;  // file being swept, -1 when none
  int64_t send_rate_bps = 0;  // measured over the last second
  int64_t target_bps = 0;     // current rate limit
  uint32_t repairs = 0;       // blocks resent
};

struct SenderCallbacks {
  // Invoked on the sender thread; the owner marshals to its loop.
  std::function<void(uint16_t index, const std::string& sha256)> on_file_done;
  std::function<void()> on_all_done;  // every file acknowledged with file_ok
  std::function<void(const std::string& code, const std::string& message)> on_error;
};

class SenderTransfer {
 public:
  static constexpr size_t kMaxInflightFiles = 8;
  static constexpr uint32_t kBucketBlocks = 256;
  static constexpr uint32_t kMaxRepairsPerPass = 4096;
  static constexpr int kLinkDownTimeoutMs = 20000;

  SenderTransfer(BlockLink* link, SenderCallbacks cbs);
  ~SenderTransfer();
  SenderTransfer(const SenderTransfer&) = delete;
  SenderTransfer& operator=(const SenderTransfer&) = delete;

  // `files` parallels manifest.files. `have` lists, per file index, block
  // runs the receiver already holds (resume); `verified` lists files the
  // receiver already verified (skipped entirely). Starts the sender thread.
  bool Start(const Manifest& manifest, const std::vector<std::filesystem::path>& files,
             const std::map<uint16_t, std::vector<SackRun>>& have,
             const std::vector<uint16_t>& verified, std::string* error);

  // Any thread (typically the transport thread).
  void OnSack(const uint8_t* data, size_t len);
  // Owner thread: the receiver verified this file.
  void OnFileOk(uint16_t index);
  // Owner thread: the receiver's verification failed and it discarded the
  // file; forget the blocks it claimed to have so repair resends them all.
  void OnFileBad(uint16_t index);

  void SetPaused(bool paused);
  bool Paused() const { return paused_.load(); }
  // Stops the thread and joins. Safe to call more than once.
  void Stop();
  bool Finished() const { return finished_.load(); }

  SenderProgress Progress() const;

 private:
  struct FileTx {
    uint16_t index = 0;
    uint64_t size = 0;
    uint32_t blocks = 0;
    std::filesystem::path path;
    std::mutex skip_mutex;
    BlockBitmap skip;                          // blocks the receiver already has
    std::vector<uint32_t> sweep_ms;            // send time per bucket
    std::map<uint32_t, uint32_t> repair_ms;    // send time of repaired blocks
    bool sweep_done = false;
    std::string sha256;
    std::unique_ptr<FileReader> reader;
    std::atomic<bool> ok{false};
    std::atomic<bool> announced{false};
    // Latest SACK (transport thread writes, sender thread reads).
    std::mutex sack_mutex;
    Sack sack;
    uint32_t sack_seq = 0;
    uint64_t acked_bytes = 0;
  };

  void Run();
  bool SweepFile(FileTx& f);
  bool RepairPass(bool* did_work);
  bool RepairFile(FileTx& f, uint32_t now, uint32_t hold, uint32_t* budget);
  bool ReadBlocks(FileTx& f, uint32_t first_block, uint32_t count, std::vector<uint8_t>* buf,
                  size_t* got);
  bool WaitTokens(size_t bytes);
  bool SendBlock(FileTx& f, uint32_t block, const uint8_t* payload, uint16_t len, bool repair);
  uint32_t LastSent(const FileTx& f, uint32_t block) const;
  void UpdateRate();
  uint32_t NowMs() const;
  double NowMsExact() const;
  bool PauseWait();
  void Fail(const std::string& code, const std::string& message);
  void ReapInflight();

  BlockLink* link_;
  SenderCallbacks cbs_;
  Manifest manifest_;
  std::vector<std::filesystem::path> files_;

  std::thread thread_;
  std::atomic<bool> stop_{false};
  std::atomic<bool> paused_{false};
  std::atomic<bool> finished_{false};
  std::atomic<bool> failed_{false};
  std::mutex pause_mutex_;
  std::condition_variable pause_cv_;

  std::vector<std::unique_ptr<FileTx>> tx_;  // one per manifest file
  std::vector<FileTx*> inflight_;            // sender thread only
  std::chrono::steady_clock::time_point start_;

  // Rate control (sender thread only).
  double tokens_ = 0;
  double last_token_ms_ = 0;
  int64_t target_bps_ = 0;
  int64_t aimd_bps_ = 200'000'000;
  int rtt_ms_ = 100;
  uint32_t last_rate_update_ms_ = 0;
  uint64_t window_bytes_ = 0;
  uint32_t window_start_ms_ = 0;
  uint32_t link_down_since_ms_ = 0;

  // Progress (atomics for cross-thread reads).
  std::atomic<uint64_t> bytes_sent_{0};
  std::atomic<uint64_t> bytes_acked_{0};
  std::atomic<uint32_t> files_done_{0};
  std::atomic<int32_t> current_file_{-1};
  std::atomic<int64_t> send_rate_bps_{0};
  std::atomic<int64_t> target_bps_atomic_{0};
  std::atomic<uint32_t> repairs_{0};
  std::atomic<uint16_t> max_loss_permille_{0};
};

}  // namespace ct

#endif  // CT_TRANSFER_SENDER_H_
