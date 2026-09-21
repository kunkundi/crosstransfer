// End-to-end test of SenderTransfer <-> ReceiverTransfer over an in-memory
// lossy datagram pipe, with a fake ctrl channel for file_done / file_ok.
#include <cstdint>
#include <doctest/doctest.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "transfer/manifest.h"
#include "transfer/protocol.h"
#include "transfer/receiver.h"
#include "transfer/sender.h"
#include "transfer/sha256.h"

using namespace ct;
namespace fs = std::filesystem;

namespace {

// Two directional lossy pipes with a delivery thread each.
class Pipe : public BlockLink {
 public:
  Pipe(std::string name, double loss, int delay_ms) : name_(std::move(name)), loss_(loss), delay_ms_(delay_ms) {}
  ~Pipe() override { Stop(); }
  void SetPeer(std::function<void(const char*, const uint8_t*, size_t)> deliver) { deliver_ = std::move(deliver); }
  void Start() {
    running_ = true;
    thread_ = std::thread([this] { Run(); });
  }
  void Stop() {
    running_ = false;
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
  }
  int SendDatagram(const char* stream, const uint8_t* data, size_t len) override {
    if (!running_) return -1;
    std::lock_guard<std::mutex> lock(mu_);
    if (queue_.size() > 20000) return 1;  // backpressure
    queue_.push_back({stream, std::vector<uint8_t>(data, data + len),
                      std::chrono::steady_clock::now() + std::chrono::milliseconds(delay_ms_)});
    cv_.notify_one();
    return 0;
  }
  bool LinkEstimate(int64_t* bwe, int* rtt) override {
    *bwe = 400'000'000;
    *rtt = delay_ms_ * 2 + 1;
    return true;
  }
  uint64_t delivered = 0, dropped = 0;

 private:
  struct Item {
    std::string stream;
    std::vector<uint8_t> data;
    std::chrono::steady_clock::time_point due;
  };
  void Run() {
    std::mt19937 rng(12345);
    std::uniform_real_distribution<double> u(0, 1);
    while (running_) {
      Item it;
      {
        std::unique_lock<std::mutex> lock(mu_);
        cv_.wait(lock, [&] { return !running_ || !queue_.empty(); });
        if (!running_) return;
        if (queue_.front().due > std::chrono::steady_clock::now()) {
          cv_.wait_until(lock, queue_.front().due);
          continue;
        }
        it = std::move(queue_.front());
        queue_.pop_front();
      }
      if (u(rng) < loss_) {
        ++dropped;
        continue;
      }
      ++delivered;
      deliver_(it.stream.c_str(), it.data.data(), it.data.size());
    }
  }
  std::string name_;
  double loss_;
  int delay_ms_;
  std::function<void(const char*, const uint8_t*, size_t)> deliver_;
  std::thread thread_;
  std::atomic<bool> running_{false};
  std::mutex mu_;
  std::condition_variable cv_;
  std::deque<Item> queue_;
};

void WriteRandomFile(const fs::path& p, size_t size, uint32_t seed) {
  std::mt19937 rng(seed);
  std::ofstream out(p, std::ios::binary);
  std::vector<char> buf(65536);
  size_t left = size;
  while (left > 0) {
    const size_t n = std::min(left, buf.size());
    for (size_t i = 0; i < n; ++i) buf[i] = static_cast<char>(rng());
    out.write(buf.data(), static_cast<std::streamsize>(n));
    left -= n;
  }
}

bool SameContent(const fs::path& a, const fs::path& b) {
  std::string ha, hb;
  return Sha256File(a, &ha) && Sha256File(b, &hb) && ha == hb;
}

struct Harness {
  fs::path root, src, dst;
  Manifest manifest;
  std::vector<fs::path> files;
  Pipe s2r{"s2r", 0, 0}, r2s{"r2s", 0, 0};
  std::unique_ptr<SenderTransfer> sender;
  std::unique_ptr<ReceiverTransfer> receiver;
  std::atomic<bool> sender_done{false}, receiver_done{false}, failed{false};
  std::string fail_msg;
  std::mutex ctrl_mu;
  std::vector<std::pair<uint16_t, std::string>> file_done_queue;
  std::vector<uint16_t> file_ok_queue;
  std::vector<uint16_t> file_bad_queue;
  std::atomic<int> persists{0};
  std::atomic<int> file_bads{0};

  Harness(double loss, int delay) : s2r("s2r", loss, delay), r2s("r2s", loss, delay) {
    root = fs::temp_directory_path() / ("ct_e2e_" + std::to_string(std::random_device{}()));
    src = root / "src";
    dst = root / "dst";
    fs::create_directories(src);
    fs::create_directories(dst);
  }
  ~Harness() {
    if (sender) sender->Stop();
    if (receiver) receiver->Stop();
    s2r.Stop();
    r2s.Stop();
    fs::remove_all(root);
  }

  void Build(const std::vector<std::string>& roots) {
    std::string err;
    REQUIRE_MESSAGE(BuildManifest(roots, &manifest, &files, &err), err);
  }

  void Run(int timeout_sec, const std::vector<ReceiverFileState>& resume = {}) {
    SenderCallbacks scb;
    scb.on_file_done = [&](uint16_t i, const std::string& h) {
      std::lock_guard<std::mutex> lock(ctrl_mu);
      file_done_queue.push_back({i, h});
    };
    scb.on_all_done = [&] { sender_done = true; };
    scb.on_error = [&](const std::string& c, const std::string& m) {
      failed = true;
      fail_msg = "sender " + c + ": " + m;
    };
    ReceiverCallbacks rcb;
    rcb.on_file_ok = [&](uint16_t i) {
      std::lock_guard<std::mutex> lock(ctrl_mu);
      file_ok_queue.push_back(i);
    };
    rcb.on_file_bad = [&](uint16_t i, const std::string&) {
      ++file_bads;
      std::lock_guard<std::mutex> lock(ctrl_mu);
      file_bad_queue.push_back(i);
    };
    rcb.on_all_done = [&] { receiver_done = true; };
    rcb.on_error = [&](const std::string& c, const std::string& m) {
      failed = true;
      fail_msg = "receiver " + c + ": " + m;
    };
    rcb.on_persist = [&](const std::vector<ReceiverFileState>&) { ++persists; };

    sender = std::make_unique<SenderTransfer>(&r2s_link(), scb);
    receiver = std::make_unique<ReceiverTransfer>(&s2r_link(), rcb);
    s2r.SetPeer([&](const char* stream, const uint8_t* d, size_t n) {
      if (std::string(stream) == kStreamData) receiver->OnBlock(d, n);
    });
    r2s.SetPeer([&](const char* stream, const uint8_t* d, size_t n) {
      if (std::string(stream) == kStreamSack) sender->OnSack(d, n);
    });
    s2r.Start();
    r2s.Start();
    std::string err;
    std::map<std::string, std::string> names;
    REQUIRE_MESSAGE(receiver->Start(manifest, dst, names, resume, &err), err);
    REQUIRE(sender->Start(manifest, files, receiver->HaveRuns(), receiver->VerifiedFiles(), &err));

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeout_sec);
    while (std::chrono::steady_clock::now() < deadline) {
      // Fake reliable ctrl channel.
      std::vector<std::pair<uint16_t, std::string>> fd;
      std::vector<uint16_t> fo, fb;
      {
        std::lock_guard<std::mutex> lock(ctrl_mu);
        fd.swap(file_done_queue);
        fo.swap(file_ok_queue);
        fb.swap(file_bad_queue);
      }
      for (auto& [i, h] : fd) receiver->OnFileDone(i, h);
      for (auto i : fo) sender->OnFileOk(i);
      for (auto i : fb) sender->OnFileBad(i);
      if ((sender_done && receiver_done) || failed) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
  }
  // Sender writes data into the s2r pipe; receiver writes SACKs into r2s.
  BlockLink& r2s_link() { return s2r; }
  BlockLink& s2r_link() { return r2s; }
};

}  // namespace

TEST_CASE("transfer: mixed files over a clean pipe") {
  Harness h(0.0, 0);
  fs::create_directories(h.src / "dir" / "empty");
  WriteRandomFile(h.src / "dir" / "a.bin", 3 * 1024 * 1024 + 123, 1);
  WriteRandomFile(h.src / "dir" / "one_block.bin", kBlockPayloadSize, 2);
  WriteRandomFile(h.src / "dir" / "tiny.bin", 1, 3);
  WriteRandomFile(h.src / "dir" / "zero.bin", 0, 4);
  WriteRandomFile(h.src / "single.bin", 100000, 5);
  h.Build({(h.src / "dir").string(), (h.src / "single.bin").string()});
  h.Run(30);
  CHECK_MESSAGE(!h.failed, h.fail_msg);
  CHECK(h.sender_done);
  CHECK(h.receiver_done);
  CHECK(SameContent(h.src / "dir" / "a.bin", h.dst / "dir" / "a.bin"));
  CHECK(SameContent(h.src / "dir" / "one_block.bin", h.dst / "dir" / "one_block.bin"));
  CHECK(SameContent(h.src / "dir" / "tiny.bin", h.dst / "dir" / "tiny.bin"));
  CHECK(fs::file_size(h.dst / "dir" / "zero.bin") == 0);
  CHECK(fs::is_directory(h.dst / "dir" / "empty"));
  CHECK(SameContent(h.src / "single.bin", h.dst / "single.bin"));
  CHECK_FALSE(fs::exists(h.dst / "single.bin.ctpart"));
  const auto sp = h.sender->Progress();
  CHECK(sp.bytes_acked == h.manifest.total_bytes);
  CHECK(sp.files_done == 5);
  CHECK(sp.repairs == 0);
  const auto rp = h.receiver->Progress();
  CHECK(rp.bytes_received == h.manifest.total_bytes);
  CHECK(rp.files_done == 5);
}

TEST_CASE("transfer: 5% loss with delay repairs to completion") {
  Harness h(0.05, 5);
  WriteRandomFile(h.src / "big.bin", 2 * 1024 * 1024 + 777, 7);
  WriteRandomFile(h.src / "small.bin", 5000, 8);
  h.Build({(h.src / "big.bin").string(), (h.src / "small.bin").string()});
  h.Run(60);
  CHECK_MESSAGE(!h.failed, h.fail_msg);
  CHECK(h.sender_done);
  CHECK(h.receiver_done);
  CHECK(SameContent(h.src / "big.bin", h.dst / "big.bin"));
  CHECK(SameContent(h.src / "small.bin", h.dst / "small.bin"));
  CHECK(h.sender->Progress().repairs > 0);
  CHECK(h.s2r.dropped > 0);
}

TEST_CASE("transfer: resume from persisted bitmap") {
  Harness h(0.0, 0);
  WriteRandomFile(h.src / "r.bin", 1024 * 1024, 9);
  h.Build({(h.src / "r.bin").string()});

  // Simulate a partial first run: receiver holds blocks [0,200) and [300,350).
  std::vector<ReceiverFileState> resume(1);
  resume[0].index = 0;
  resume[0].have = {{0, 200}, {300, 50}};
  // Pre-create the part file with the correct content for those blocks and
  // garbage elsewhere (the sender skips them, so garbage would fail SHA if
  // the bitmap were wrong).
  {
    std::ifstream in(h.src / "r.bin", std::ios::binary);
    std::vector<char> all((std::istreambuf_iterator<char>(in)), {});
    std::vector<char> part(all.size(), 'Z');
    auto copy = [&](uint32_t s, uint32_t n) {
      const size_t off = static_cast<size_t>(s) * kBlockPayloadSize;
      const size_t len = std::min(static_cast<size_t>(n) * kBlockPayloadSize, all.size() - off);
      std::copy(all.begin() + off, all.begin() + off + len, part.begin() + off);
    };
    copy(0, 200);
    copy(300, 50);
    std::ofstream(h.dst / "r.bin.ctpart", std::ios::binary).write(part.data(), part.size());
  }
  h.Run(30, resume);
  CHECK_MESSAGE(!h.failed, h.fail_msg);
  CHECK(h.receiver_done);
  CHECK(SameContent(h.src / "r.bin", h.dst / "r.bin"));
  // 250 of 954 blocks were skipped.
  const auto sp = h.sender->Progress();
  CHECK(sp.bytes_sent < h.manifest.total_bytes);
  CHECK(h.persists > 0);
}

TEST_CASE("transfer: corrupted file is detected and re-sent") {
  Harness h(0.0, 0);
  WriteRandomFile(h.src / "c.bin", 200 * 1024, 10);
  h.Build({(h.src / "c.bin").string()});
  // Claim the receiver already has blocks [0,50) but the part file holds garbage
  // there: verification fails, receiver resets the file, sender must resend.
  std::vector<ReceiverFileState> resume(1);
  resume[0].index = 0;
  resume[0].have = {{0, 50}};
  {
    std::vector<char> part(200 * 1024, 'Q');
    std::ofstream(h.dst / "c.bin.ctpart", std::ios::binary).write(part.data(), part.size());
  }
  // file_bad flows back over the fake ctrl channel: the sender forgets the
  // skipped blocks and repair resends the whole file.
  h.Run(30, resume);
  CHECK_MESSAGE(!h.failed, h.fail_msg);
  CHECK(h.receiver_done);
  CHECK(h.file_bads == 1);
  CHECK(SameContent(h.src / "c.bin", h.dst / "c.bin"));
}

TEST_CASE("transfer: duplicate final block in one batch does not write a closed file") {
  Harness h(0.0, 0);
  WriteRandomFile(h.src / "data.bin", 777, 11);
  WriteRandomFile(h.src / "zero.bin", 0, 12);
  h.Build({(h.src / "data.bin").string(), (h.src / "zero.bin").string()});
  REQUIRE(h.manifest.files[0].path == "data.bin");
  REQUIRE(h.manifest.files[1].path == "zero.bin");
  std::ifstream in(h.src / "data.bin", std::ios::binary);
  std::vector<uint8_t> payload((std::istreambuf_iterator<char>(in)), {});
  std::vector<uint8_t> wire(kBlockHeaderSize + payload.size());
  BlockHeader header;
  header.len = static_cast<uint16_t>(payload.size());
  REQUIRE(EncodeBlock(header, payload.data(), wire.data(), wire.size()) == wire.size());
  ReceiverCallbacks callbacks;
  callbacks.on_error = [&](const std::string&, const std::string&) { h.failed = true; };
  callbacks.on_all_done = [&] { h.receiver_done = true; };
  callbacks.on_file_ok = [&](uint16_t index) {
    if (index != 1) return;
    // The data hash has already been consumed, and this callback runs on the
    // writer thread: both copies deterministically enter the next single batch.
    h.receiver->OnBlock(wire.data(), wire.size());
    h.receiver->OnBlock(wire.data(), wire.size());
  };
  h.receiver = std::make_unique<ReceiverTransfer>(&h.r2s, callbacks);
  std::string error, hash;
  REQUIRE(h.receiver->Start(h.manifest, h.dst, {}, {}, &error));
  REQUIRE(Sha256File(h.src / "data.bin", &hash));
  h.receiver->OnFileDone(0, hash);
  h.receiver->OnFileDone(1, Sha256Hex("", 0));
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (!h.receiver_done && !h.failed && std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  h.receiver->Stop();
  CHECK_FALSE(h.failed);
  CHECK(h.receiver_done);
  CHECK(h.receiver->Progress().bytes_received == 777);
  CHECK(h.receiver->Progress().files_done == 2);
  CHECK(SameContent(h.src / "data.bin", h.dst / "data.bin"));
}
