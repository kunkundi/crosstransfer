// data_echo: end-to-end check of the specialised MiniRTC against a local
// ctserver. One process acts as the sender (creates a share), the other claims
// the code. Both sides then exchange reliable ("ctrl") and unreliable ("data")
// messages and report throughput.
//
//   data_echo share   --server 127.0.0.1 --port 8080 [--turn auto|force|off] [--no-srtp] [--relay-only]
//   data_echo receive --code XXXXX-XXXXX --server 127.0.0.1 --port 8080 [...]
//
// Exit code 0 when the echo round trip completes on both stream kinds.

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "minirtc.h"

namespace {

struct State {
  std::mutex mu;
  std::condition_variable cv;
  std::string session_id;
  std::string code;
  bool signal_ready = false;
  bool connected = false;
  bool failed = false;
  std::string fail_reason;
  MiniRtcPath path = MINIRTC_PATH_UNKNOWN;
  std::atomic<uint64_t> ctrl_rx{0}, data_rx{0}, data_rx_bytes{0};
  std::atomic<int64_t> last_seq{-1};
  std::string role;
  MiniRtcPeer* peer = nullptr;
};

void OnSignal(MiniRtcSignalStatus st, const char* peer_id, void* ud) {
  auto* s = static_cast<State*>(ud);
  std::printf("[signal] %d peer=%s\n", st, peer_id ? peer_id : "");
  std::lock_guard<std::mutex> lock(s->mu);
  if (st == MINIRTC_SIGNAL_CONNECTED) s->signal_ready = true;
  if (st == MINIRTC_SIGNAL_FAILED || st == MINIRTC_SIGNAL_TLS_ERROR) {
    s->failed = true;
    s->fail_reason = "signal";
  }
  s->cv.notify_all();
}

void OnShare(MiniRtcShareEvent ev, const char* share_id, const char* code,
             int64_t expires_at, const char* detail, void* ud) {
  auto* s = static_cast<State*>(ud);
  std::lock_guard<std::mutex> lock(s->mu);
  if (ev == MINIRTC_SHARE_CREATED) {
    s->code = code;
    std::printf("[share] created id=%s code=%s (%s) expires_at=%lld\n", share_id,
                code, detail, (long long)expires_at);
  } else if (ev == MINIRTC_SHARE_CLAIMED) {
    std::printf("[share] claimed session=%s\n", detail);
  } else if (ev == MINIRTC_SHARE_FAILED) {
    std::printf("[share] failed: %s\n", detail);
    s->failed = true;
    s->fail_reason = detail;
  } else {
    std::printf("[share] closed: %s\n", detail);
  }
  s->cv.notify_all();
}

void OnClaim(MiniRtcClaimResult r, const char* session_id, const char* token,
             const char* message, void* ud) {
  auto* s = static_cast<State*>(ud);
  std::printf("[claim] result=%d session=%s token=%s %s\n", r, session_id, token,
              message);
  if (r != MINIRTC_CLAIM_OK) {
    std::lock_guard<std::mutex> lock(s->mu);
    s->failed = true;
    s->fail_reason = "claim";
    s->cv.notify_all();
  }
}

void OnSession(MiniRtcSessionStatus st, const char* sid, const char* role,
               const char*, const char* meta, MiniRtcPath path, const char* reason,
               void* ud) {
  auto* s = static_cast<State*>(ud);
  std::printf("[session] %s status=%d role=%s path=%d reason=%s meta=%s\n", sid,
              st, role, path, reason, meta);
  std::lock_guard<std::mutex> lock(s->mu);
  s->session_id = sid;
  s->role = role;
  if (st == MINIRTC_SESSION_CONNECTED) {
    s->connected = true;
    s->path = path;
  } else if (st == MINIRTC_SESSION_FAILED || st == MINIRTC_SESSION_CLOSED ||
             st == MINIRTC_SESSION_DISCONNECTED) {
    if (!s->connected) {
      s->failed = true;
      s->fail_reason = reason;
    }
    s->connected = false;
  }
  s->cv.notify_all();
}

void OnData(const uint8_t* data, size_t len, const char* sid, const char* stream,
            void* ud) {
  auto* s = static_cast<State*>(ud);
  if (std::strcmp(stream, "ctrl") == 0) {
    s->ctrl_rx.fetch_add(1);
    std::string msg(reinterpret_cast<const char*>(data), len);
    if (s->role == "sender" && msg.rfind("ping", 0) == 0) {
      const std::string reply = "pong" + msg.substr(4);
      minirtc_send(s->peer, sid, "ctrl", reply.data(), reply.size());
    }
  } else {
    s->data_rx.fetch_add(1);
    s->data_rx_bytes.fetch_add(len);
    if (len >= 4) {
      uint32_t seq;
      std::memcpy(&seq, data, 4);
      s->last_seq.store(seq);
    }
  }
}

void OnStats(const char* sid, const MiniRtcNetStats* st, void* ud) {
  auto* s = static_cast<State*>(ud);
  std::printf(
      "[stats] %s tx=%u kbps rx=%u kbps bwe=%lld kbps pace=%lld kbps rtt=%d "
      "loss=%.2f path=%d srtp=%d ctrl_rx=%llu data_rx=%llu\n",
      sid, st->send_bitrate_bps / 1000, st->recv_bitrate_bps / 1000,
      (long long)st->link.bwe_bps / 1000, (long long)st->link.pacing_bps / 1000,
      st->link.rtt_ms, st->link.loss, st->link.path, st->link.srtp_active,
      (unsigned long long)s->ctrl_rx.load(), (unsigned long long)s->data_rx.load());
}

template <typename Pred>
bool WaitFor(State& s, int timeout_ms, Pred pred) {
  std::unique_lock<std::mutex> lock(s.mu);
  return s.cv.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                       [&] { return s.failed || pred(); }) &&
         !s.failed;
}

int Usage() {
  std::fprintf(stderr,
               "usage: data_echo share|receive [--code C] [--server H] [--port P] "
               "[--tls] [--turn auto|force|off] [--no-srtp] [--relay-only] "
               "[--seconds N] [--rate-kbps R]\n");
  return 2;
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  if (argc < 2) return Usage();
  const std::string cmd = argv[1];
  std::string code, server = "127.0.0.1";
  int port = 8080, seconds = 5, rate_kbps = 20000;
  bool tls = false, srtp = true, relay_only = false;
  MiniRtcTurnMode turn = MINIRTC_TURN_AUTO;
  for (int i = 2; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&](std::string& out) {
      if (i + 1 >= argc) return false;
      out = argv[++i];
      return true;
    };
    std::string v;
    if (a == "--code" && next(v)) code = v;
    else if (a == "--server" && next(v)) server = v;
    else if (a == "--port" && next(v)) port = std::stoi(v);
    else if (a == "--tls") tls = true;
    else if (a == "--no-srtp") srtp = false;
    else if (a == "--relay-only") relay_only = true;
    else if (a == "--seconds" && next(v)) seconds = std::stoi(v);
    else if (a == "--rate-kbps" && next(v)) rate_kbps = std::stoi(v);
    else if (a == "--turn" && next(v)) {
      turn = v == "force" ? MINIRTC_TURN_FORCE
             : v == "off" ? MINIRTC_TURN_DISABLED
                          : MINIRTC_TURN_AUTO;
    } else {
      return Usage();
    }
  }
  if (cmd != "share" && cmd != "receive") return Usage();
  if (cmd == "receive" && code.empty()) return Usage();

  State st;
  MiniRtcParams p{};
  p.server_host = server.c_str();
  p.server_port = port;
  p.server_tls = tls;
  p.server_path = "/ws";
  p.log_dir = "logs";
  p.turn_mode = turn;
  p.enable_srtp = srtp;
  p.enable_upnp = false;
  p.enable_ws_relay = true;
  p.force_ws_relay = relay_only;
  p.ice_timeout_ms = 15000;
  p.app = "data_echo";
  p.version = minirtc_version();
  p.platform = "cli";
  p.on_signal_status = OnSignal;
  p.on_share_event = OnShare;
  p.on_claim_result = OnClaim;
  p.on_session_status = OnSession;
  p.on_receive_data = OnData;
  p.on_net_stats = OnStats;
  p.user_data = &st;

  MiniRtcPeer* peer = minirtc_create(&p);
  if (!peer) {
    std::fprintf(stderr, "minirtc_create failed\n");
    return 1;
  }
  st.peer = peer;
  minirtc_add_data_stream(peer, "ctrl", true);
  minirtc_add_data_stream(peer, "data", false);
  if (minirtc_connect(peer) != 0) {
    std::fprintf(stderr, "minirtc_connect failed\n");
    return 1;
  }
  if (!WaitFor(st, 10000, [&] { return st.signal_ready; })) {
    std::fprintf(stderr, "signaling not ready (%s)\n", st.fail_reason.c_str());
    minirtc_destroy(&peer);
    return 1;
  }

  if (cmd == "share") {
    minirtc_create_share(peer, "once", 600, R"({"files":1,"bytes":0})");
    if (!WaitFor(st, 5000, [&] { return !st.code.empty(); })) {
      std::fprintf(stderr, "create_share failed\n");
      minirtc_destroy(&peer);
      return 1;
    }
    std::printf("CODE %s\n", st.code.c_str());
    std::fflush(stdout);
  } else {
    minirtc_claim(peer, code.c_str(), nullptr);
  }

  if (!WaitFor(st, 60000, [&] { return st.connected; })) {
    std::fprintf(stderr, "session not connected (%s)\n", st.fail_reason.c_str());
    minirtc_destroy(&peer);
    return 1;
  }
  std::string sid;
  {
    std::lock_guard<std::mutex> lock(st.mu);
    sid = st.session_id;
  }
  std::printf("CONNECTED path=%d\n", st.path);

  int rc = 0;
  if (cmd == "receive") {
    // Reliable ping/pong.
    for (int i = 0; i < 20; ++i) {
      const std::string msg = "ping" + std::to_string(i);
      while (minirtc_send(peer, sid.c_str(), "ctrl", msg.data(), msg.size()) == 1)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    // Unreliable bulk: paced by BWE; count deliveries at the peer via stats.
    const size_t payload = minirtc_max_datagram_size();
    std::vector<uint8_t> buf(payload, 0xAB);
    const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
    uint32_t seq = 0;
    uint64_t sent = 0;
    const double bytes_per_ms = rate_kbps * 1000.0 / 8.0 / 1000.0;
    auto t0 = std::chrono::steady_clock::now();
    double budget = 0;
    while (std::chrono::steady_clock::now() < end) {
      auto now = std::chrono::steady_clock::now();
      budget += std::chrono::duration<double, std::milli>(now - t0).count() * bytes_per_ms;
      t0 = now;
      int burst = 0;
      while (budget >= (double)payload && burst < 64) {
        std::memcpy(buf.data(), &seq, 4);
        const int r = minirtc_send(peer, sid.c_str(), "data", buf.data(), payload);
        if (r == 0) {
          ++seq;
          ++sent;
          budget -= payload;
        } else {
          break;  // backpressure or not ready
        }
        ++burst;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    // Tell the sender we are done and wait for pongs.
    const std::string done = "ping-done";
    minirtc_send(peer, sid.c_str(), "ctrl", done.data(), done.size());
    std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    std::printf("RESULT sent_data=%llu pong_rx=%llu\n", (unsigned long long)sent,
                (unsigned long long)st.ctrl_rx.load());
    rc = st.ctrl_rx.load() >= 21 ? 0 : 1;
  } else {
    // Sender: wait for the receiver to finish (ping-done) then report.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(seconds + 30);
    while (std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(200));
      bool connected;
      {
        std::lock_guard<std::mutex> lock(st.mu);
        connected = st.connected;
      }
      if (!connected || st.ctrl_rx.load() >= 21) break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    std::printf("RESULT ctrl_rx=%llu data_rx=%llu data_bytes=%llu last_seq=%lld\n",
                (unsigned long long)st.ctrl_rx.load(),
                (unsigned long long)st.data_rx.load(),
                (unsigned long long)st.data_rx_bytes.load(),
                (long long)st.last_seq.load());
    rc = (st.ctrl_rx.load() >= 21 && st.data_rx.load() > 0) ? 0 : 1;
  }
  minirtc_leave(peer, sid.c_str());
  minirtc_destroy(&peer);
  return rc;
}
