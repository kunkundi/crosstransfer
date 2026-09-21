// ct_cli — command line client for CrossTransfer.
//
//   ct_cli share   <paths...> [--mode once|open] [--ttl SEC] [--wait N] [--exit-on-complete]
//   ct_cli receive <code|link> [--dir DIR]
//   ct_cli resume  <transfer_id>
//   ct_cli list
//
// Common flags: --server HOST[:PORT] --tls/--no-tls --data-dir DIR --turn auto|force|off
//               --relay auto|force|off --no-srtp --log-level LVL --json --link-host HOST
//
// Events from the core are printed as one JSON object per line with --json,
// or as human readable progress otherwise. Exit code 0 on completion.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

#include "crosstransfer/ct_api.h"

namespace {

using nlohmann::json;

struct Options {
  std::string cmd;
  std::vector<std::string> args;
  std::string server_host = "127.0.0.1";
  int server_port = 8080;
  bool tls = false;
  std::string data_dir;
  std::string save_dir;
  std::string turn = "auto";
  std::string relay = "auto";
  bool srtp = true;
  std::string log_level = "warn";
  std::string link_host;
  std::string mode;
  int ttl = 0;
  int wait_receivers = 1;  // share: exit after N completed receivers (0 = forever)
  bool json_out = false;
  int timeout_sec = 0;
};

int Usage() {
  std::fprintf(stderr,
               "usage:\n"
               "  ct_cli share   <paths...> [--mode once|open] [--ttl SEC] [--wait N]\n"
               "  ct_cli receive <code|link> [--dir DIR]\n"
               "  ct_cli resume  <transfer_id>\n"
               "  ct_cli list\n"
               "common: --server HOST[:PORT] [--tls] --data-dir DIR --turn auto|force|off\n"
               "        --relay auto|force|off --no-srtp --log-level LVL --json --link-host HOST\n"
               "        --timeout SEC\n");
  return 2;
}

bool Parse(int argc, char** argv, Options* o) {
  if (argc < 2) return false;
  o->cmd = argv[1];
  for (int i = 2; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&](std::string* out) {
      if (i + 1 >= argc) return false;
      *out = argv[++i];
      return true;
    };
    std::string v;
    if (a == "--server" && next(&v)) {
      const size_t colon = v.rfind(':');
      if (colon != std::string::npos && v.find(']') == std::string::npos) {
        o->server_host = v.substr(0, colon);
        o->server_port = std::atoi(v.c_str() + colon + 1);
      } else {
        o->server_host = v;
      }
    } else if (a == "--tls") {
      o->tls = true;
    } else if (a == "--no-tls") {
      o->tls = false;
    } else if (a == "--data-dir" && next(&v)) {
      o->data_dir = v;
    } else if (a == "--dir" && next(&v)) {
      o->save_dir = v;
    } else if (a == "--turn" && next(&v)) {
      o->turn = v;
    } else if (a == "--relay" && next(&v)) {
      o->relay = v;
    } else if (a == "--no-srtp") {
      o->srtp = false;
    } else if (a == "--log-level" && next(&v)) {
      o->log_level = v;
    } else if (a == "--link-host" && next(&v)) {
      o->link_host = v;
    } else if (a == "--mode" && next(&v)) {
      o->mode = v;
    } else if (a == "--ttl" && next(&v)) {
      o->ttl = std::atoi(v.c_str());
    } else if (a == "--wait" && next(&v)) {
      o->wait_receivers = std::atoi(v.c_str());
    } else if (a == "--timeout" && next(&v)) {
      o->timeout_sec = std::atoi(v.c_str());
    } else if (a == "--json") {
      o->json_out = true;
    } else if (!a.empty() && a[0] == '-') {
      std::fprintf(stderr, "unknown flag %s\n", a.c_str());
      return false;
    } else {
      o->args.push_back(a);
    }
  }
  return true;
}

std::string HumanBytes(uint64_t b) {
  const char* units[] = {"B", "KiB", "MiB", "GiB", "TiB"};
  double v = static_cast<double>(b);
  int u = 0;
  while (v >= 1024 && u < 4) {
    v /= 1024;
    ++u;
  }
  char buf[64];
  std::snprintf(buf, sizeof(buf), u == 0 ? "%.0f %s" : "%.1f %s", v, units[u]);
  return buf;
}

struct App {
  Options opt;
  CtCore* core = nullptr;
  std::mutex mu;
  std::condition_variable cv;
  bool done = false;
  int exit_code = 1;
  std::string share_id, transfer_id;
  int completed_receivers = 0;
  std::string last_line;

  void OnEvent(const json& ev) {
    const std::string type = ev.value("type", "");
    if (opt.json_out) {
      std::printf("%s\n", ev.dump().c_str());
      std::fflush(stdout);
    }
    std::lock_guard<std::mutex> lock(mu);
    if (type == "signal_state") {
      if (!opt.json_out) std::fprintf(stderr, "[signal] %s\n", ev.value("state", "").c_str());
      const std::string st = ev.value("state", "");
      if (st == "failed" || st == "tls_error") Finish(1);
    } else if (type == "share_state") {
      const std::string st = ev.value("state", "");
      if (!opt.json_out) {
        if (st == "ready") {
          std::printf("CODE %s\nLINK %s\n", ev.value("code", "").c_str(), ev.value("link", "").c_str());
          std::printf("waiting for receiver...\n");
          std::fflush(stdout);
        } else {
          std::fprintf(stderr, "[share] %s %s\n", st.c_str(), ev.value("error", "").c_str());
        }
      }
      if (st == "failed") Finish(1);
      if (st == "closed" && ev.value("receivers", 0) == 0) Finish(1);
    } else if (type == "receive_state") {
      const std::string st = ev.value("state", "");
      if (!opt.json_out) std::fprintf(stderr, "[receive] %s %s\n", st.c_str(), ev.value("error_code", "").c_str());
      if (st == "failed") Finish(1);
      if (st == "cancelled") Finish(1);
    } else if (type == "transfer_progress") {
      if (!opt.json_out) {
        const uint64_t done_b = ev.value("bytes_done", 0ull), total = ev.value("bytes_total", 0ull);
        const double pct = total ? 100.0 * static_cast<double>(done_b) / static_cast<double>(total) : 0;
        char buf[256];
        std::snprintf(buf, sizeof(buf), "\r%5.1f%%  %s / %s  %s/s  files %d/%d  path %s   ", pct,
                      HumanBytes(done_b).c_str(), HumanBytes(total).c_str(),
                      HumanBytes(static_cast<uint64_t>(ev.value("rate_bps", 0ll) / 8)).c_str(),
                      ev.value("files_done", 0), ev.value("files_total", 0),
                      ev.value("path", "").c_str());
        std::fputs(buf, stderr);
      }
    } else if (type == "transfer_state") {
      const std::string st = ev.value("state", "");
      const std::string role = ev.value("role", "");
      if (!opt.json_out) {
        std::fprintf(stderr, "\n[transfer] %s %s %s\n", role.c_str(), st.c_str(),
                     ev.value("error_code", "").c_str());
      }
      if (st == "completed") {
        if (role == "receiver") {
          std::printf("DONE %s\n", opt.save_dir.c_str());
          std::fflush(stdout);
          Finish(0);
        } else {
          ++completed_receivers;
          if (opt.wait_receivers > 0 && completed_receivers >= opt.wait_receivers) Finish(0);
        }
      } else if (st == "failed" || st == "cancelled") {
        if (role == "receiver") Finish(1);
        // sender: a failed receiver may retry; keep waiting for once-mode
        // resume unless the share itself ends.
      }
    } else if (type == "error") {
      std::fprintf(stderr, "[error] %s\n", ev.dump().c_str());
    }
  }
  void Finish(int code) {  // mu held
    if (done) return;
    done = true;
    exit_code = code;
    cv.notify_all();
  }
};

App* g_app = nullptr;

void OnSignal(int) {
  if (g_app) {
    std::lock_guard<std::mutex> lock(g_app->mu);
    g_app->Finish(130);
  }
}

void EventThunk(const char* json_utf8, void* ud) {
  auto* app = static_cast<App*>(ud);
  json ev = json::parse(json_utf8, nullptr, false);
  if (!ev.is_discarded()) app->OnEvent(ev);
}

}  // namespace

int main(int argc, char** argv) {
  App app;
  g_app = &app;
  if (!Parse(argc, argv, &app.opt)) return Usage();
  Options& o = app.opt;
  if (o.data_dir.empty()) {
    const char* home = std::getenv("HOME");
    o.data_dir = (std::filesystem::path(home ? home : ".") / ".crosstransfer").string();
  }
  if (o.save_dir.empty()) o.save_dir = (std::filesystem::path(o.data_dir) / "received").string();

  json cfg = {
      {"data_dir", o.data_dir},
      {"log_level", o.log_level},
      {"server", {{"host", o.server_host}, {"port", o.server_port}, {"tls", o.tls}, {"path", "/ws"}}},
      {"turn_mode", o.turn},
      {"ws_relay", o.relay},
      {"enable_srtp", o.srtp},
      {"save_dir", o.save_dir},
      {"app_version", CtVersion()},
      {"platform", "cli"},
  };
  if (!o.link_host.empty()) cfg["link_host"] = o.link_host;

  app.core = CtCreate(cfg.dump().c_str());
  if (!app.core) {
    std::fprintf(stderr, "CtCreate failed (check --data-dir)\n");
    return 1;
  }
  CtSetEventCallback(app.core, &EventThunk, &app);
  std::signal(SIGINT, OnSignal);
  std::signal(SIGTERM, OnSignal);

  int rc = 0;
  if (o.cmd == "share") {
    if (o.args.empty()) return Usage();
    json paths = json::array();
    for (const auto& p : o.args) paths.push_back(std::filesystem::absolute(p).string());
    json options = json::object();
    if (!o.mode.empty()) options["mode"] = o.mode;
    if (o.ttl > 0) options["ttl_sec"] = o.ttl;
    const char* id = nullptr;
    rc = CtShareCreate(app.core, paths.dump().c_str(), options.dump().c_str(), &id);
    if (rc != CT_OK) {
      std::fprintf(stderr, "share create failed: %d\n", rc);
      CtDestroy(app.core);
      return 1;
    }
    app.share_id = id;
    CtFreeString(id);
  } else if (o.cmd == "receive") {
    if (o.args.size() != 1) return Usage();
    const char* id = nullptr;
    rc = CtReceiveStart(app.core, o.args[0].c_str(), o.save_dir.c_str(), &id);
    if (rc != CT_OK) {
      std::fprintf(stderr, "invalid take-code or link\n");
      CtDestroy(app.core);
      return 1;
    }
    app.transfer_id = id;
    CtFreeString(id);
  } else if (o.cmd == "resume") {
    if (o.args.size() != 1) return Usage();
    app.transfer_id = o.args[0];
    CtReceiveResume(app.core, o.args[0].c_str());
  } else if (o.cmd == "list") {
    const char* q = CtQuery(app.core, R"({"what":"all"})");
    std::printf("%s\n", q ? q : "{}");
    CtFreeString(q);
    CtDestroy(app.core);
    return 0;
  } else {
    CtDestroy(app.core);
    return Usage();
  }

  {
    std::unique_lock<std::mutex> lock(app.mu);
    if (o.timeout_sec > 0) {
      if (!app.cv.wait_for(lock, std::chrono::seconds(o.timeout_sec), [&] { return app.done; })) {
        std::fprintf(stderr, "timeout\n");
        app.exit_code = 124;
      }
    } else {
      app.cv.wait(lock, [&] { return app.done; });
    }
  }
  if (o.cmd == "share" && !app.share_id.empty()) CtShareClose(app.core, app.share_id.c_str());
  // Give the final ctrl messages a moment to flush before tearing down.
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  CtSetEventCallback(app.core, nullptr, nullptr);
  CtDestroy(app.core);
  g_app = nullptr;
  return app.exit_code;
}
