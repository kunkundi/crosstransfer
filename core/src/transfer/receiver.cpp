/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "transfer/receiver.h"

#include <algorithm>
#include <cstdint>
#include <system_error>

#include "log/log.h"
#include "transfer/path_sanitize.h"
#include "transfer/protocol.h"
#include "transfer/sha256.h"

namespace ct {
namespace {

constexpr uint32_t kPersistIntervalMs = 2000;
constexpr uint32_t kRateWindowMs = 500;
constexpr uint32_t kCompleteSackRepeats = 5;

}  // namespace

ReceiverTransfer::ReceiverTransfer(BlockLink* link, ReceiverCallbacks cbs)
    : link_(link), cbs_(std::move(cbs)) {}

ReceiverTransfer::~ReceiverTransfer() { Stop(); }

bool ReceiverTransfer::Start(const Manifest& manifest, const std::filesystem::path& save_dir,
                             const std::map<std::string, std::string>& final_names,
                             const std::vector<ReceiverFileState>& resume, std::string* error) {
  auto fail = [&](const std::string& msg) {
    if (error) *error = msg;
    return false;
  };
  if (thread_.joinable()) return fail("already started");
  manifest_ = manifest;
  save_dir_ = save_dir;
  std::string err;
  if (!EnsureDir(save_dir_, &err)) return fail("save dir: " + err);

  // Map a manifest path to its on-disk relative path with the root renamed.
  auto mapped = [&](const std::string& rel) {
    const size_t slash = rel.find('/');
    const std::string root = rel.substr(0, slash);
    auto it = final_names.find(root);
    const std::string head = it == final_names.end() ? root : it->second;
    return slash == std::string::npos ? head : head + rel.substr(slash);
  };

  // Directories (parents first; manifest dirs are sorted).
  for (const auto& d : manifest_.dirs) {
    const auto p = paths::JoinSafe(save_dir_, mapped(d));
    std::error_code ec;
    const bool existed = std::filesystem::exists(p, ec);
    if (!EnsureDir(p, &err)) return fail("mkdir: " + err);
    if (!existed) created_dirs_.push_back(p);
  }

  std::map<uint16_t, const ReceiverFileState*> resume_by_index;
  for (const auto& s : resume) resume_by_index[s.index] = &s;

  rx_.clear();
  for (size_t i = 0; i < manifest_.files.size(); ++i) {
    auto f = std::make_unique<FileRx>();
    f->index = static_cast<uint16_t>(i);
    f->size = manifest_.files[i].size;
    f->blocks = BlockCountFor(f->size);
    f->final_path = paths::JoinSafe(save_dir_, mapped(manifest_.files[i].path));
    f->part_path = f->final_path;
    f->part_path += ".ctpart";
    f->bitmap.Reset(f->blocks);
    auto rit = resume_by_index.find(f->index);
    std::error_code ec;
    if (rit != resume_by_index.end() && rit->second->verified &&
        std::filesystem::is_regular_file(f->final_path, ec)) {
      f->verified = true;
      f->complete = true;
      f->bitmap.SetRuns({{0, f->blocks}});
      bytes_received_.fetch_add(f->size);
      files_done_.fetch_add(1);
      rx_.push_back(std::move(f));
      continue;
    }
    const auto parent = f->final_path.parent_path();
    if (!EnsureDir(parent, &err)) return fail("mkdir: " + err);
    if (f->blocks == 0) {
      // Empty file: nothing to receive; created on verification.
      f->complete = true;
      rx_.push_back(std::move(f));
      continue;
    }
    f->writer = std::make_unique<FileWriter>();
    const bool part_exists = std::filesystem::is_regular_file(f->part_path, ec);
    if (!f->writer->Open(f->part_path, &err)) return fail("open part: " + err);
    if (!f->writer->EnsureSize(f->size)) return fail("allocate part file");
    if (rit != resume_by_index.end() && part_exists) {
      f->bitmap.SetRuns(rit->second->have);
      bytes_received_.fetch_add(std::min<uint64_t>(
          static_cast<uint64_t>(f->bitmap.count()) * kBlockPayloadSize, f->size));
      f->frontier = f->bitmap.AckBase();
      if (f->bitmap.Complete()) f->complete = true;
    }
    rx_.push_back(std::move(f));
  }
  start_ = std::chrono::steady_clock::now();
  stop_ = false;
  thread_ = std::thread([this] { Run(); });
  return true;
}

std::map<uint16_t, std::vector<SackRun>> ReceiverTransfer::HaveRuns() const {
  std::lock_guard<std::mutex> lock(state_mutex_);
  std::map<uint16_t, std::vector<SackRun>> out;
  for (const auto& f : rx_) {
    if (f->verified || f->bitmap.count() == 0) continue;
    out[f->index] = f->bitmap.HaveRuns(1u << 20);
  }
  return out;
}

std::vector<uint16_t> ReceiverTransfer::VerifiedFiles() const {
  std::lock_guard<std::mutex> lock(state_mutex_);
  std::vector<uint16_t> out;
  for (const auto& f : rx_) {
    if (f->verified) out.push_back(f->index);
  }
  return out;
}

std::vector<ReceiverFileState> ReceiverTransfer::Snapshot() const {
  std::lock_guard<std::mutex> lock(state_mutex_);
  std::vector<ReceiverFileState> out;
  for (const auto& f : rx_) {
    ReceiverFileState s;
    s.index = f->index;
    s.verified = f->verified;
    if (!f->verified) s.have = f->bitmap.HaveRuns(1u << 20);
    out.push_back(std::move(s));
  }
  return out;
}

ReceiverProgress ReceiverTransfer::Progress() const {
  ReceiverProgress p;
  p.bytes_total = manifest_.total_bytes;
  p.bytes_received = std::min<uint64_t>(bytes_received_.load(), manifest_.total_bytes);
  p.files_total = static_cast<uint32_t>(manifest_.files.size());
  p.files_done = files_done_.load();
  p.current_file = current_file_.load();
  p.recv_rate_bps = recv_rate_bps_.load();
  p.loss_permille = loss_permille_.load();
  p.duplicates = duplicates_.load();
  return p;
}

uint32_t ReceiverTransfer::NowMs() const {
  return static_cast<uint32_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                   std::chrono::steady_clock::now() - start_)
                                   .count());
}

void ReceiverTransfer::Fail(const std::string& code, const std::string& message) {
  if (failed_.exchange(true)) return;
  CT_LOG_ERROR("receiver failed: {} {}", code, message);
  if (cbs_.on_error) cbs_.on_error(code, message);
}

// ---- transport thread ---------------------------------------------------------

void ReceiverTransfer::OnBlock(const uint8_t* data, size_t len) {
  BlockHeader h;
  const uint8_t* payload = nullptr;
  if (!DecodeBlock(data, len, &h, &payload)) return;
  if (h.file_index >= rx_.size()) return;
  Pending p;
  p.file = h.file_index;
  p.block = h.block_index;
  p.len = h.len;
  p.payload.assign(payload, payload + h.len);
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (queue_bytes_ + h.len > kMaxQueueBytes) return;  // disk cannot keep up; SACK will repair
    queue_bytes_ += h.len;
    queue_.push_back(std::move(p));
  }
  queue_cv_.notify_one();
}

void ReceiverTransfer::OnFileDone(uint16_t index, const std::string& sha256) {
  {
    std::lock_guard<std::mutex> lock(done_mutex_);
    pending_done_[index] = sha256;
  }
  queue_cv_.notify_one();
}

void ReceiverTransfer::Stop() {
  stop_ = true;
  queue_cv_.notify_all();
  if (thread_.joinable()) thread_.join();
  for (auto& f : rx_) {
    if (f->writer) {
      f->writer->Flush();
      f->writer.reset();
    }
  }
}

void ReceiverTransfer::Cleanup() {
  Stop();
  std::error_code ec;
  for (auto& f : rx_) {
    if (!f->verified) std::filesystem::remove(f->part_path, ec);
  }
  // Remove directories we created, deepest first, only if empty.
  for (auto it = created_dirs_.rbegin(); it != created_dirs_.rend(); ++it) {
    if (std::filesystem::is_empty(*it, ec) && !ec) std::filesystem::remove(*it, ec);
  }
}

// ---- writer thread -------------------------------------------------------------

void ReceiverTransfer::Run() {
  // Files that are already complete (empty or fully resumed) still need
  // verification once their hash arrives.
  bool initial_check = true;
  while (!stop_.load() && !failed_.load()) {
    std::deque<Pending> batch;
    {
      std::unique_lock<std::mutex> lock(queue_mutex_);
      queue_cv_.wait_for(lock, std::chrono::milliseconds(kSackIntervalMs / 2), [&] {
        return stop_.load() || !queue_.empty() || !pending_done_.empty();
      });
      batch.swap(queue_);
      queue_bytes_ = 0;
    }
    const uint32_t now = NowMs();
    HandleBatch(batch, now);
    if (failed_.load()) return;
    std::map<uint16_t, std::string> done;
    {
      std::lock_guard<std::mutex> lock(done_mutex_);
      done.swap(pending_done_);
    }
    for (auto& [index, hash] : done) {
      if (index >= rx_.size()) continue;
      rx_[index]->expected_sha256 = hash;
      MaybeVerify(*rx_[index]);
    }
    if (initial_check) {
      initial_check = false;
      for (auto& f : rx_) {
        if (f->complete && !f->verified) f->dirty = true;
      }
    }
    SendSacks(now, false);
    UpdateRates(now);
    Persist(false);
    if (AllVerified()) {
      Persist(true);
      finished_ = true;
      if (cbs_.on_all_done) cbs_.on_all_done();
      return;
    }
  }
  Persist(true);
}

bool ReceiverTransfer::AcceptBlock(const Pending& p) {
  FileRx& f = *rx_[p.file];
  if (f.verified || f.blocks == 0 || p.block >= f.blocks) return false;
  if (p.len != BlockLenFor(f.size, p.block)) return false;
  current_file_ = f.index;
  f.dirty = true;
  // Loss estimate: blocks skipped between consecutive new arrivals beyond
  // the frontier count as expected-but-missing for this window.
  if (p.block >= f.frontier) {
    f.expected_since_sack += p.block - f.frontier + 1;
    f.frontier = p.block + 1;
  }
  bool fresh;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    fresh = !f.bitmap.Test(p.block);
  }
  if (!fresh) duplicates_.fetch_add(1);
  return fresh;
}

bool ReceiverTransfer::FlushRun(FileRx& f, uint32_t first_block, const std::vector<uint8_t>& data,
                                const std::vector<uint32_t>& blocks, uint32_t now) {
  if (blocks.empty()) return true;
  if (!f.writer || !f.writer->WriteAt(static_cast<uint64_t>(first_block) * kBlockPayloadSize,
                                      data.data(), data.size())) {
    Fail("io", "write failed: " + paths::ToUtf8(f.final_path.filename()));
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    for (uint32_t b : blocks) f.bitmap.Set(b);
    if (f.bitmap.Complete()) f.complete = true;
  }
  f.received_since_sack += static_cast<uint32_t>(blocks.size());
  rate_received_ += static_cast<uint32_t>(blocks.size());
  rate_bytes_ += data.size();
  bytes_received_.fetch_add(data.size());
  if (f.complete) {
    SendSack(f, now);
    MaybeVerify(f);
  }
  return true;
}

// Blocks arrive mostly in order; contiguous fresh blocks of one file are
// written with a single pwrite instead of one syscall per 1100 bytes.
void ReceiverTransfer::HandleBatch(std::deque<Pending>& batch, uint32_t now) {
  std::vector<uint8_t> run_data;
  std::vector<uint32_t> run_blocks;
  FileRx* run_file = nullptr;
  uint32_t run_first = 0;
  auto flush = [&]() -> bool {
    if (!run_file) return true;
    const bool ok = FlushRun(*run_file, run_first, run_data, run_blocks, now);
    run_data.clear();
    run_blocks.clear();
    run_file = nullptr;
    return ok;
  };
  for (const auto& p : batch) {
    if (!AcceptBlock(p)) continue;
    FileRx& f = *rx_[p.file];
    const bool contiguous = run_file == &f && !run_blocks.empty() &&
                            p.block == run_blocks.back() + 1 &&
                            run_data.size() == run_blocks.size() * kBlockPayloadSize;
    if (!contiguous) {
      if (!flush()) return;
      run_file = &f;
      run_first = p.block;
    }
    run_data.insert(run_data.end(), p.payload.begin(), p.payload.end());
    run_blocks.push_back(p.block);
    if (run_data.size() >= (1u << 20)) {
      if (!flush()) return;
    }
  }
  flush();
}

void ReceiverTransfer::SendSacks(uint32_t now, bool force) {
  for (auto& fp : rx_) {
    FileRx& f = *fp;
    if (f.verified) continue;
    if (f.complete) {
      // Keep telling the sender until file_ok flows back through ctrl.
      if (f.complete_sacks_sent < kCompleteSackRepeats &&
          now - f.last_sack_ms >= static_cast<uint32_t>(kSackCompleteRepeatMs)) {
        SendSack(f, now);
      }
      continue;
    }
    if (!f.dirty && !force) continue;
    if (!force && now - f.last_sack_ms < static_cast<uint32_t>(kSackIntervalMs)) continue;
    SendSack(f, now);
  }
}

void ReceiverTransfer::SendSack(FileRx& f, uint32_t now) {
  Sack s;
  s.file_index = f.index;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    s.ack_base = f.bitmap.AckBase();
    s.received_count = f.bitmap.count();
    if (f.bitmap.Complete()) s.flags |= kSackFlagComplete;
    s.frontier = std::max(f.frontier, s.ack_base);
    if (!(s.flags & kSackFlagComplete)) s.holes = f.bitmap.Holes(s.ack_base, kSackMaxRuns);
  }
  // Only report holes below the frontier; the sender infers the tail itself.
  while (!s.holes.empty() && s.holes.back().start >= s.frontier) s.holes.pop_back();
  if (!s.holes.empty()) {
    auto& last = s.holes.back();
    if (last.start + last.length > s.frontier) last.length = s.frontier - last.start;
  }
  s.recv_rate_bps = static_cast<uint32_t>(std::min<int64_t>(recv_rate_bps_.load(), UINT32_MAX));
  s.loss_permille = loss_permille_.load();
  const auto wire = EncodeSack(s);
  link_->SendDatagram(kStreamSack, wire.data(), wire.size());
  f.last_sack_ms = now;
  f.dirty = false;
  if (s.flags & kSackFlagComplete) ++f.complete_sacks_sent;
  rate_expected_ += f.expected_since_sack;
  f.expected_since_sack = 0;
  f.received_since_sack = 0;
}

void ReceiverTransfer::MaybeVerify(FileRx& f) {
  if (f.verified || f.verifying || !f.complete || f.expected_sha256.empty()) return;
  f.verifying = true;
  if (f.writer) {
    f.writer->Flush();
    f.writer.reset();
  }
  std::string hex;
  bool ok;
  std::error_code ec;
  if (f.blocks == 0) {
    ok = CreateEmptyFile(f.part_path);
    hex = Sha256Hex("", 0);
  } else {
    ok = Sha256File(f.part_path, &hex, [this] { return stop_.load(); });
  }
  if (stop_.load()) {
    f.verifying = false;
    return;
  }
  if (!ok) {
    Fail("io", "verify read failed");
    return;
  }
  if (hex != f.expected_sha256) {
    CT_LOG_WARN("sha256 mismatch for file {} ({} != {})", f.index, hex, f.expected_sha256);
    // Start over for this file: clear bitmap, keep the part file.
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      const uint64_t had = std::min<uint64_t>(
          static_cast<uint64_t>(f.bitmap.count()) * kBlockPayloadSize, f.size);
      bytes_received_.fetch_sub(std::min(bytes_received_.load(), had));
      f.bitmap.Reset(f.blocks);
    }
    f.complete = false;
    f.verifying = false;
    f.frontier = 0;
    f.complete_sacks_sent = 0;
    // Keep expected_sha256: the sender's hash is still the truth and the
    // file is verified again once every block has been received anew.
    if (f.blocks > 0) {
      f.writer = std::make_unique<FileWriter>();
      f.writer->Open(f.part_path);
    }
    if (cbs_.on_file_bad) cbs_.on_file_bad(f.index, "sha256_mismatch");
    return;
  }
  std::string err;
  if (!RenameReplace(f.part_path, f.final_path, &err)) {
    Fail("io", "rename failed: " + err);
    return;
  }
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    f.verified = true;
  }
  f.verifying = false;
  files_done_.fetch_add(1);
  if (cbs_.on_file_ok) cbs_.on_file_ok(f.index);
}

void ReceiverTransfer::Persist(bool force) {
  const uint32_t now = NowMs();
  if (!force && now - last_persist_ms_ < kPersistIntervalMs) return;
  last_persist_ms_ = now;
  for (auto& f : rx_) {
    if (f->writer) f->writer->Flush();
  }
  if (cbs_.on_persist) cbs_.on_persist(Snapshot());
}

void ReceiverTransfer::UpdateRates(uint32_t now) {
  if (now - last_rate_ms_ < kRateWindowMs) return;
  const uint32_t elapsed = now - last_rate_ms_;
  last_rate_ms_ = now;
  recv_rate_bps_ = static_cast<int64_t>(rate_bytes_ * 8000 / elapsed);
  rate_bytes_ = 0;
  if (rate_expected_ > 0) {
    const uint32_t lost = rate_expected_ > rate_received_ ? rate_expected_ - rate_received_ : 0;
    loss_permille_ = static_cast<uint16_t>(std::min<uint32_t>(1000, lost * 1000 / rate_expected_));
  } else {
    loss_permille_ = 0;
  }
  rate_expected_ = 0;
  rate_received_ = 0;
}

bool ReceiverTransfer::AllVerified() const {
  for (const auto& f : rx_) {
    if (!f->verified) return false;
  }
  return true;
}

}  // namespace ct
