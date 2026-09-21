/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "transfer/sender.h"

#include <algorithm>
#include <cstdint>
#include <cstring>

#include "log/log.h"
#include "transfer/protocol.h"
#include "transfer/sha256.h"

namespace ct {
namespace {

constexpr int64_t kMinRateBps = 300'000;
constexpr int64_t kMaxRateBps = 1'000'000'000;
constexpr uint32_t kRateUpdateMs = 200;
constexpr uint32_t kReadChunkBlocks = 256;  // 281 KiB per read

}  // namespace

SenderTransfer::SenderTransfer(BlockLink* link, SenderCallbacks cbs)
    : link_(link), cbs_(std::move(cbs)) {}

SenderTransfer::~SenderTransfer() { Stop(); }

bool SenderTransfer::Start(const Manifest& manifest,
                           const std::vector<std::filesystem::path>& files,
                           const std::map<uint16_t, std::vector<SackRun>>& have,
                           const std::vector<uint16_t>& verified, std::string* error) {
  if (thread_.joinable()) {
    if (error) *error = "already started";
    return false;
  }
  if (files.size() != manifest.files.size()) {
    if (error) *error = "manifest / file list mismatch";
    return false;
  }
  manifest_ = manifest;
  files_ = files;
  tx_.clear();
  tx_.reserve(manifest.files.size());
  for (size_t i = 0; i < manifest.files.size(); ++i) {
    auto f = std::make_unique<FileTx>();
    f->index = static_cast<uint16_t>(i);
    f->size = manifest.files[i].size;
    f->blocks = BlockCountFor(f->size);
    f->path = files[i];
    f->skip.Reset(f->blocks);
    auto it = have.find(f->index);
    if (it != have.end()) f->skip.SetRuns(it->second);
    f->sweep_ms.assign((f->blocks + kBucketBlocks - 1) / kBucketBlocks, 0);
    tx_.push_back(std::move(f));
  }
  for (uint16_t v : verified) {
    if (v < tx_.size()) {
      tx_[v]->ok = true;
      tx_[v]->announced = true;
      files_done_.fetch_add(1);
      bytes_acked_.fetch_add(tx_[v]->size);
    }
  }
  start_ = std::chrono::steady_clock::now();
  stop_ = false;
  thread_ = std::thread([this] { Run(); });
  return true;
}

void SenderTransfer::Stop() {
  stop_ = true;
  pause_cv_.notify_all();
  if (thread_.joinable()) thread_.join();
}

void SenderTransfer::SetPaused(bool paused) {
  {
    std::lock_guard<std::mutex> lock(pause_mutex_);
    paused_ = paused;
  }
  pause_cv_.notify_all();
}

bool SenderTransfer::PauseWait() {
  if (!paused_.load()) return !stop_.load();
  std::unique_lock<std::mutex> lock(pause_mutex_);
  pause_cv_.wait(lock, [&] { return !paused_.load() || stop_.load(); });
  // Do not let tokens accumulate during the pause.
  last_token_ms_ = NowMsExact();
  tokens_ = 0;
  return !stop_.load();
}

SenderProgress SenderTransfer::Progress() const {
  SenderProgress p;
  p.bytes_total = manifest_.total_bytes;
  p.bytes_sent = bytes_sent_.load();
  p.bytes_acked = std::min<uint64_t>(bytes_acked_.load(), manifest_.total_bytes);
  p.files_total = static_cast<uint32_t>(manifest_.files.size());
  p.files_done = files_done_.load();
  p.current_file = current_file_.load();
  p.send_rate_bps = send_rate_bps_.load();
  p.target_bps = target_bps_atomic_.load();
  p.repairs = repairs_.load();
  return p;
}

uint32_t SenderTransfer::NowMs() const {
  return static_cast<uint32_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                   std::chrono::steady_clock::now() - start_)
                                   .count());
}

double SenderTransfer::NowMsExact() const {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start_)
      .count();
}

void SenderTransfer::Fail(const std::string& code, const std::string& message) {
  if (failed_.exchange(true)) return;
  CT_LOG_ERROR("sender failed: {} {}", code, message);
  if (cbs_.on_error) cbs_.on_error(code, message);
}

// ---- SACK intake (transport thread) -----------------------------------------

void SenderTransfer::OnSack(const uint8_t* data, size_t len) {
  Sack s;
  if (!DecodeSack(data, len, &s)) return;
  if (s.file_index >= tx_.size()) return;
  FileTx& f = *tx_[s.file_index];
  uint64_t acked = std::min<uint64_t>(static_cast<uint64_t>(s.received_count) * kBlockPayloadSize,
                                      f.size);
  if (s.flags & kSackFlagComplete) acked = f.size;
  {
    std::lock_guard<std::mutex> lock(f.sack_mutex);
    // received_count only grows at the receiver; ignore reordered older SACKs.
    if (f.sack_seq > 0 && s.received_count < f.sack.received_count) return;
    f.sack = std::move(s);
    ++f.sack_seq;
    if (acked > f.acked_bytes) {
      bytes_acked_.fetch_add(acked - f.acked_bytes);
      f.acked_bytes = acked;
    }
  }
  uint16_t loss = f.sack.loss_permille;
  uint16_t cur = max_loss_permille_.load();
  while (loss > cur && !max_loss_permille_.compare_exchange_weak(cur, loss)) {
  }
}

void SenderTransfer::OnFileBad(uint16_t index) {
  if (index >= tx_.size()) return;
  FileTx& f = *tx_[index];
  if (f.ok.load()) return;
  {
    std::lock_guard<std::mutex> lock(f.skip_mutex);
    f.skip.Reset(f.blocks);
  }
  std::lock_guard<std::mutex> lock(f.sack_mutex);
  if (f.acked_bytes > 0) {
    bytes_acked_.fetch_sub(std::min(bytes_acked_.load(), f.acked_bytes));
    f.acked_bytes = 0;
  }
  f.sack = Sack{};
  f.sack_seq = 0;
}

void SenderTransfer::OnFileOk(uint16_t index) {
  if (index >= tx_.size()) return;
  FileTx& f = *tx_[index];
  if (f.ok.exchange(true)) return;
  {
    std::lock_guard<std::mutex> lock(f.sack_mutex);
    if (f.size > f.acked_bytes) {
      bytes_acked_.fetch_add(f.size - f.acked_bytes);
      f.acked_bytes = f.size;
    }
  }
  files_done_.fetch_add(1);
}

// ---- sender thread -----------------------------------------------------------

void SenderTransfer::Run() {
  last_token_ms_ = NowMsExact();
  window_start_ms_ = NowMs();
  UpdateRate();
  for (auto& fp : tx_) {
    FileTx& f = *fp;
    if (stop_.load() || failed_.load()) break;
    if (f.ok.load()) continue;  // verified in a previous run
    current_file_ = f.index;
    if (f.blocks == 0) {
      f.sha256 = Sha256Hex("", 0);
      f.sweep_done = true;
    } else if (!SweepFile(f)) {
      break;
    }
    if (!f.announced.exchange(true) && cbs_.on_file_done) cbs_.on_file_done(f.index, f.sha256);
    inflight_.push_back(&f);
    while (!stop_.load() && !failed_.load()) {
      ReapInflight();
      if (inflight_.size() < kMaxInflightFiles) break;
      bool did_work = false;
      if (!RepairPass(&did_work)) break;
      if (!did_work) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
  }
  current_file_ = -1;
  while (!stop_.load() && !failed_.load()) {
    ReapInflight();
    if (inflight_.empty()) break;
    bool did_work = false;
    if (!RepairPass(&did_work)) break;
    if (!did_work) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  for (auto& fp : tx_) fp->reader.reset();
  if (!stop_.load() && !failed_.load()) {
    finished_ = true;
    if (cbs_.on_all_done) cbs_.on_all_done();
  }
}

void SenderTransfer::ReapInflight() {
  for (auto it = inflight_.begin(); it != inflight_.end();) {
    if ((*it)->ok.load()) {
      (*it)->reader.reset();
      (*it)->repair_ms.clear();
      it = inflight_.erase(it);
    } else {
      ++it;
    }
  }
}

bool SenderTransfer::ReadBlocks(FileTx& f, uint32_t first_block, uint32_t count,
                                std::vector<uint8_t>* buf, size_t* got) {
  if (!f.reader) {
    f.reader = std::make_unique<FileReader>();
    std::string err;
    if (!f.reader->Open(f.path, &err)) {
      Fail("io", "open failed: " + err);
      return false;
    }
    if (f.reader->Size() != f.size) {
      Fail("file_changed", "file size changed: " + f.path.filename().string());
      return false;
    }
  }
  const uint64_t offset = static_cast<uint64_t>(first_block) * kBlockPayloadSize;
  const uint64_t want = std::min<uint64_t>(static_cast<uint64_t>(count) * kBlockPayloadSize,
                                           f.size - std::min(f.size, offset));
  buf->resize(static_cast<size_t>(want));
  if (!f.reader->ReadAt(offset, buf->data(), buf->size(), got) || *got != want) {
    Fail("io", "read failed: " + f.path.filename().string());
    return false;
  }
  return true;
}

bool SenderTransfer::SweepFile(FileTx& f) {
  Sha256 hasher;
  std::vector<uint8_t> buf;
  uint32_t block = 0;
  uint32_t since_repair = 0;
  while (block < f.blocks) {
    if (!PauseWait()) return false;
    const uint32_t n = std::min(kReadChunkBlocks, f.blocks - block);
    size_t got = 0;
    if (!ReadBlocks(f, block, n, &buf, &got)) return false;
    hasher.Update(buf.data(), got);
    for (uint32_t i = 0; i < n; ++i, ++block) {
      const uint16_t len = BlockLenFor(f.size, block);
      const uint8_t* payload = buf.data() + static_cast<size_t>(i) * kBlockPayloadSize;
      bool skip;
      {
        std::lock_guard<std::mutex> lock(f.skip_mutex);
        skip = f.skip.Test(block);
      }
      if (!skip) {
        if (!WaitTokens(len)) return false;
        if (!SendBlock(f, block, payload, len, false)) return false;
      }
      f.sweep_ms[block / kBucketBlocks] = NowMs();
      if (++since_repair >= 64) {
        since_repair = 0;
        ReapInflight();
        bool did_work = false;
        if (!RepairPass(&did_work)) return false;
      }
    }
  }
  f.sha256 = hasher.FinishHex();
  f.sweep_done = true;
  return true;
}

uint32_t SenderTransfer::LastSent(const FileTx& f, uint32_t block) const {
  uint32_t t = f.sweep_ms[block / kBucketBlocks];
  auto it = f.repair_ms.find(block);
  if (it != f.repair_ms.end() && it->second > t) t = it->second;
  return t;
}

bool SenderTransfer::RepairPass(bool* did_work) {
  *did_work = false;
  if (inflight_.empty()) return true;
  const uint32_t now = NowMs();
  const uint32_t hold = std::max<uint32_t>(
      kRepairMinHoldMs, static_cast<uint32_t>(rtt_ms_ * 3 / 2) + kSackIntervalMs);
  uint32_t budget = kMaxRepairsPerPass;
  for (FileTx* f : std::vector<FileTx*>(inflight_)) {
    if (f->ok.load()) continue;
    const uint32_t before = budget;
    if (!RepairFile(*f, now, hold, &budget)) return false;
    if (budget != before) *did_work = true;
    if (budget == 0) break;
  }
  return true;
}

bool SenderTransfer::RepairFile(FileTx& f, uint32_t now, uint32_t hold, uint32_t* budget) {
  Sack sack;
  uint32_t seq;
  {
    std::lock_guard<std::mutex> lock(f.sack_mutex);
    sack = f.sack;
    seq = f.sack_seq;
  }
  if (seq > 0 && (sack.flags & kSackFlagComplete)) return true;
  std::vector<SackRun> holes;
  if (seq > 0) holes = sack.holes;
  if (f.sweep_done) {
    // Blocks the receiver has never seen (beyond its frontier).
    const uint32_t frontier = seq > 0 ? std::max(sack.frontier, sack.ack_base) : 0;
    if (frontier < f.blocks) holes.push_back({frontier, f.blocks - frontier});
  }
  if (holes.empty()) return true;
  // Drop repair timestamps below ack_base; they can never be needed again.
  if (seq > 0) f.repair_ms.erase(f.repair_ms.begin(), f.repair_ms.lower_bound(sack.ack_base));

  std::vector<uint8_t> buf;
  for (const auto& run : holes) {
    uint64_t end64 = static_cast<uint64_t>(run.start) + run.length;
    const uint32_t end = static_cast<uint32_t>(std::min<uint64_t>(end64, f.blocks));
    for (uint32_t block = run.start; block < end && *budget > 0; ++block) {
      {
        std::lock_guard<std::mutex> lock(f.skip_mutex);
        if (f.skip.Test(block)) continue;  // receiver reported having it at accept
      }
      const uint32_t last = LastSent(f, block);
      if (last != 0 && now - last < hold) continue;
      if (!PauseWait()) return false;
      size_t got = 0;
      if (!ReadBlocks(f, block, 1, &buf, &got)) return false;
      const uint16_t len = BlockLenFor(f.size, block);
      if (!WaitTokens(len)) return false;
      if (!SendBlock(f, block, buf.data(), len, true)) return false;
      f.repair_ms[block] = NowMs();
      --*budget;
    }
    if (*budget == 0) break;
  }
  return true;
}

bool SenderTransfer::SendBlock(FileTx& f, uint32_t block, const uint8_t* payload, uint16_t len,
                               bool repair) {
  uint8_t wire[kBlockHeaderSize + kBlockPayloadSize];
  BlockHeader h;
  h.flags = block + 1 == f.blocks ? kBlockFlagLast : 0;
  h.file_index = f.index;
  h.block_index = block;
  h.len = len;
  const size_t n = EncodeBlock(h, payload, wire, sizeof(wire));
  for (;;) {
    if (stop_.load()) return false;
    const int r = link_->SendDatagram(kStreamData, wire, n);
    if (r == 0) {
      link_down_since_ms_ = 0;
      bytes_sent_.fetch_add(len);
      window_bytes_ += len;
      if (repair) repairs_.fetch_add(1);
      return true;
    }
    if (r == 1) {
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
      continue;
    }
    // Transport not ready (session reconnecting or gone).
    const uint32_t now = NowMs();
    if (link_down_since_ms_ == 0) link_down_since_ms_ = now ? now : 1;
    if (now - link_down_since_ms_ > static_cast<uint32_t>(kLinkDownTimeoutMs)) {
      Fail("link_down", "transport unavailable");
      return false;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
}

bool SenderTransfer::WaitTokens(size_t bytes) {
  for (;;) {
    if (stop_.load()) return false;
    const double now = NowMsExact();
    if (NowMs() - last_rate_update_ms_ >= kRateUpdateMs) UpdateRate();
    const double rate_bytes_per_ms = static_cast<double>(target_bps_) / 8000.0;
    tokens_ += (now - last_token_ms_) * rate_bytes_per_ms;
    last_token_ms_ = now;
    const double burst = std::max(64.0 * 1024.0, rate_bytes_per_ms * 50.0);
    if (tokens_ > burst) tokens_ = burst;
    if (tokens_ >= static_cast<double>(bytes)) {
      tokens_ -= static_cast<double>(bytes);
      return true;
    }
    const double deficit_ms = (static_cast<double>(bytes) - tokens_) / rate_bytes_per_ms;
    const int sleep_ms = static_cast<int>(std::min(10.0, std::max(1.0, deficit_ms)));
    std::this_thread::sleep_for(std::chrono::milliseconds(sleep_ms));
  }
}

void SenderTransfer::UpdateRate() {
  const uint32_t now = NowMs();
  last_rate_update_ms_ = now;
  int64_t bwe = 0;
  int rtt = -1;
  if (link_ && link_->LinkEstimate(&bwe, &rtt) && rtt > 0) rtt_ms_ = rtt;

  // AIMD on receiver-reported loss (fallback and safety cap).
  const uint16_t loss = max_loss_permille_.exchange(0);
  if (loss > 100) {
    aimd_bps_ = static_cast<int64_t>(aimd_bps_ * 0.7);
  } else if (loss > 30) {
    aimd_bps_ = static_cast<int64_t>(aimd_bps_ * 0.9);
  } else {
    aimd_bps_ += 2'000'000;
  }
  aimd_bps_ = std::clamp(aimd_bps_, kMinRateBps, kMaxRateBps);

  int64_t target = aimd_bps_;
  if (bwe > 0) target = std::min(target, bwe + bwe / 10);
  target_bps_ = std::clamp(target, kMinRateBps, kMaxRateBps);
  target_bps_atomic_ = target_bps_;

  if (now - window_start_ms_ >= 1000) {
    send_rate_bps_ = static_cast<int64_t>(window_bytes_ * 8000 / (now - window_start_ms_));
    window_bytes_ = 0;
    window_start_ms_ = now;
  }
}

}  // namespace ct
