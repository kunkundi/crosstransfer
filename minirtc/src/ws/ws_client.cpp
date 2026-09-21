/*
 * Copyright (c) 2023-2026 by DI JUNKUN, All Rights Reserved.
 */

#include "ws_client.h"
#include "tls_peer_name.h"

#include <websocketpp/client.hpp>
#include <websocketpp/config/asio_client.hpp>
#include <websocketpp/config/asio_no_tls_client.hpp>

#include <algorithm>
#include <chrono>

#include "log.h"

namespace minirtc {

const char* WsStatusName(WsStatus s) {
  switch (s) {
    case WsStatus::kConnecting:
      return "connecting";
    case WsStatus::kOpen:
      return "open";
    case WsStatus::kFailed:
      return "failed";
    case WsStatus::kClosed:
      return "closed";
    case WsStatus::kReconnecting:
      return "reconnecting";
    case WsStatus::kTlsCertError:
      return "tls_cert_error";
  }
  return "?";
}

// ---------------------------------------------------------------------------
// Endpoint abstraction over the TLS and plain websocketpp client configs.
// ---------------------------------------------------------------------------

class WsEndpoint {
 public:
  virtual ~WsEndpoint() = default;
  virtual int Connect(const std::string& uri) = 0;
  virtual void Run() = 0;
  virtual void Stop() = 0;
  virtual bool Send(const void* data, size_t size, bool binary) = 0;
  virtual bool Ping() = 0;
  virtual void Close() = 0;
};

namespace {

using TlsConfig = websocketpp::config::asio_tls_client;
using PlainConfig = websocketpp::config::asio_client;
using ssl_context_ptr = std::shared_ptr<websocketpp::lib::asio::ssl::context>;

constexpr int kPingIntervalSec = 5;
constexpr int kPongTimeoutMs = 4000;

template <typename Config>
class EndpointImpl : public WsEndpoint {
 public:
  using client_t = websocketpp::client<Config>;

  explicit EndpointImpl(std::weak_ptr<WsClient> owner) : owner_(owner) {
    client_.set_error_channels(websocketpp::log::elevel::none);
    client_.set_access_channels(websocketpp::log::alevel::none);
    client_.init_asio();
    client_.start_perpetual();
    client_.set_pong_timeout(kPongTimeoutMs);
    Register();
  }

  int Connect(const std::string& uri) override {
    websocketpp::lib::error_code ec;
    auto con = client_.get_connection(uri, ec);
    if (ec || !con) {
      LOG_ERROR("get_connection error: {}", ec.message());
      return -1;
    }
    hdl_ = con->get_handle();
    client_.connect(con);
    return 0;
  }

  void Run() override { client_.run(); }

  void Stop() override {
    client_.stop_perpetual();
    client_.stop();
  }

  bool Send(const void* data, size_t size, bool binary) override {
    websocketpp::lib::error_code ec;
    auto con = client_.get_con_from_hdl(hdl_, ec);
    if (ec || !con || con->get_state() != websocketpp::session::state::open) {
      return false;
    }
    client_.send(hdl_, data, size,
                 binary ? websocketpp::frame::opcode::binary
                        : websocketpp::frame::opcode::text,
                 ec);
    if (ec) {
      LOG_WARN("WebSocket send error: {}", ec.message());
      return false;
    }
    return true;
  }

  bool Ping() override {
    websocketpp::lib::error_code ec;
    auto con = client_.get_con_from_hdl(hdl_, ec);
    if (ec || !con || con->get_state() != websocketpp::session::state::open) {
      return false;
    }
    client_.ping(hdl_, "", ec);
    return !ec;
  }

  void Close() override {
    websocketpp::lib::error_code ec;
    auto con = client_.get_con_from_hdl(hdl_, ec);
    if (!ec && con && con->get_state() == websocketpp::session::state::open) {
      client_.close(hdl_, websocketpp::close::status::normal, "bye", ec);
    }
  }

 private:
  void Register();

  std::weak_ptr<WsClient> owner_;
  client_t client_;
  websocketpp::connection_hdl hdl_;
};

template <typename Config>
void RegisterCommon(websocketpp::client<Config>& c,
                    std::weak_ptr<WsClient> owner) {
  c.set_open_handler([owner](websocketpp::connection_hdl) {
    if (auto self = owner.lock()) self->OnOpen();
  });
  c.set_fail_handler([owner, &c](websocketpp::connection_hdl hdl) {
    auto self = owner.lock();
    if (!self) return;
    auto con = c.get_con_from_hdl(hdl);
    std::string msg = con ? con->get_ec().message() : "unknown";
    std::string lower = msg;
    std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
    const bool tls = lower.find("ssl") != std::string::npos ||
                     lower.find("tls") != std::string::npos ||
                     lower.find("certificate") != std::string::npos ||
                     lower.find("handshake") != std::string::npos;
    self->OnFail(msg, tls);
  });
  c.set_close_handler([owner](websocketpp::connection_hdl) {
    if (auto self = owner.lock()) self->OnClose();
  });
  c.set_pong_handler([owner](websocketpp::connection_hdl, std::string) {
    if (auto self = owner.lock()) self->OnPong();
  });
  c.set_pong_timeout_handler([owner](websocketpp::connection_hdl, std::string) {
    if (auto self = owner.lock()) self->OnPongTimeout();
  });
  c.set_message_handler(
      [owner](websocketpp::connection_hdl,
              typename websocketpp::client<Config>::message_ptr msg) {
        auto self = owner.lock();
        if (!self) return;
        if (msg->get_opcode() == websocketpp::frame::opcode::binary) {
          self->OnBinary(msg->get_payload());
        } else {
          self->OnText(msg->get_payload());
        }
      });
}

template <>
void EndpointImpl<TlsConfig>::Register() {
  RegisterCommon(client_, owner_);
  std::weak_ptr<WsClient> owner = owner_;
  client_.set_tls_init_handler([owner](websocketpp::connection_hdl) {
    namespace asio = websocketpp::lib::asio;
    auto ctx = std::make_shared<asio::ssl::context>(asio::ssl::context::tls_client);
    try {
      ctx->set_options(asio::ssl::context::default_workarounds |
                       asio::ssl::context::no_sslv2 |
                       asio::ssl::context::no_sslv3 |
                       asio::ssl::context::no_tlsv1 |
                       asio::ssl::context::no_tlsv1_1 |
                       asio::ssl::context::single_dh_use);
      ctx->set_verify_mode(asio::ssl::verify_peer |
                           asio::ssl::verify_fail_if_no_peer_cert);
      auto self = owner.lock();
      if (!self || !self->ConfigureTls(ctx->native_handle())) return ssl_context_ptr{};
      ctx->set_verify_callback(
          [owner](bool preverified, asio::ssl::verify_context& vctx) {
            if (auto self = owner.lock()) {
              return self->OnTlsVerify(preverified, vctx.native_handle());
            }
            return false;
          });
    } catch (std::exception& e) {
      LOG_ERROR("TLS init error: {}", e.what());
      return ssl_context_ptr{};
    }
    return ctx;
  });
}

template <>
void EndpointImpl<PlainConfig>::Register() {
  RegisterCommon(client_, owner_);
}

void JoinThread(std::thread& t) {
  if (!t.joinable()) return;
  if (t.get_id() == std::this_thread::get_id()) {
    t.detach();
    return;
  }
  t.join();
}

}  // namespace

// ---------------------------------------------------------------------------

WsClient::WsClient(Callbacks callbacks) : callbacks_(std::move(callbacks)) {}

WsClient::~WsClient() { Shutdown(); }

void WsClient::SetStatus(WsStatus status) {
  status_.store(status);
  if (!shutdown_.load() && callbacks_.on_status) callbacks_.on_status(status);
}

int WsClient::Connect(const std::string& uri) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (shutdown_.load()) return -1;
  uri_ = uri;
  secure_ = uri.rfind("wss://", 0) == 0;
  if (!secure_ && uri.rfind("ws://", 0) != 0) {
    LOG_ERROR("Unsupported WebSocket URI: {}", uri);
    return -1;
  }
  StartEndpointLocked();
  return endpoint_ ? 0 : -1;
}

void WsClient::StartEndpointLocked() {
  // Stop the old endpoint without joining an I/O callback under mutex_. Its
  // thread owns the endpoint until Run() returns; Shutdown() joins the thread.
  if (endpoint_) {
    endpoint_->Stop();
    old_threads_.push_back(std::move(io_thread_));
  }
  ++generation_;
  open_ = false;
  LOG_INFO("Connecting WebSocket: {}", uri_);
  SetStatus(WsStatus::kConnecting);
  std::weak_ptr<WsClient> weak = weak_from_this();
  if (secure_) {
    endpoint_ = std::make_shared<EndpointImpl<TlsConfig>>(weak);
  } else {
    endpoint_ = std::make_shared<EndpointImpl<PlainConfig>>(weak);
  }
  if (endpoint_->Connect(uri_) != 0) {
    endpoint_.reset();
    SetStatus(WsStatus::kFailed);
    return;
  }
  auto ep = endpoint_;
  io_thread_ = std::thread([ep]() { ep->Run(); });
  if (!ping_thread_.joinable()) {
    ping_thread_ = std::thread([this]() { PingLoop(); });
  }
}

void WsClient::Shutdown() {
  if (shutdown_.exchange(true)) return;
  LOG_INFO("WebSocket shutdown");
  std::shared_ptr<WsEndpoint> ep;
  std::thread io, ping, reconnect;
  std::vector<std::thread> old;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    ep = std::move(endpoint_);
    io = std::move(io_thread_);
    ping = std::move(ping_thread_);
    reconnect = std::move(reconnect_thread_);
    old.swap(old_threads_);
  }
  cv_.notify_all();
  if (ep) {
    ep->Close();
    ep->Stop();
  }
  JoinThread(io);
  JoinThread(ping);
  JoinThread(reconnect);
  for (auto& t : old) JoinThread(t);
  ep.reset();
  status_.store(WsStatus::kClosed);
}

bool WsClient::SendText(const std::string& message) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!endpoint_ || !open_.load()) return false;
  return endpoint_->Send(message.data(), message.size(), false);
}

bool WsClient::SendBinary(const uint8_t* data, size_t size) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!endpoint_ || !open_.load()) return false;
  return endpoint_->Send(data, size, true);
}

void WsClient::PingLoop() {
  // All waits on cv_ must use the same mutex (also used by Shutdown()).
  std::unique_lock<std::mutex> lock(mutex_);
  while (!shutdown_.load()) {
    cv_.wait_for(lock, std::chrono::seconds(kPingIntervalSec),
                 [this] { return shutdown_.load(); });
    if (shutdown_.load()) break;
    if (endpoint_ && open_.load()) endpoint_->Ping();
  }
}

void WsClient::ScheduleReconnect() {
  if (shutdown_.load()) return;
  const int attempt = reconnect_attempts_.fetch_add(1);
  const int delay = std::min(1 << std::min(attempt, 6), 30);
  const uint64_t gen = generation_.load();
  LOG_INFO("WebSocket reconnect in {} s (attempt {})", delay, attempt + 1);
  SetStatus(WsStatus::kReconnecting);
  std::lock_guard<std::mutex> lock(mutex_);
  if (shutdown_.load() || generation_.load() != gen) return;
  if (reconnect_thread_.joinable()) {
    old_threads_.push_back(std::move(reconnect_thread_));
  }
  reconnect_thread_ = std::thread([this, delay, gen]() {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait_for(lock, std::chrono::seconds(delay),
                 [this] { return shutdown_.load(); });
    if (shutdown_.load() || generation_.load() != gen) return;
    StartEndpointLocked();
  });
}

void WsClient::OnOpen() {
  LOG_INFO("WebSocket connection opened");
  open_ = true;
  reconnect_attempts_ = 0;
  pong_timeouts_ = 0;
  SetStatus(WsStatus::kOpen);
}

void WsClient::OnFail(const std::string& error, bool tls_error) {
  open_ = false;
  if (tls_error) {
    LOG_ERROR("WebSocket TLS failure: {}", error);
    if (status_.load() == WsStatus::kTlsCertError) {
      // Certificate not trusted: retrying will not help.
      return;
    }
  } else {
    LOG_WARN("WebSocket connection failed: {}", error);
  }
  SetStatus(WsStatus::kFailed);
  ScheduleReconnect();
}

void WsClient::OnClose() {
  const bool was_open = open_.exchange(false);
  LOG_WARN("WebSocket connection closed");
  if (was_open) SetStatus(WsStatus::kClosed);
  ScheduleReconnect();
}

void WsClient::OnPong() { pong_timeouts_ = 0; }

void WsClient::OnPongTimeout() {
  if (++pong_timeouts_ >= 2) {
    LOG_WARN("WebSocket pong timeout, reconnecting");
    std::lock_guard<std::mutex> lock(mutex_);
    if (endpoint_) endpoint_->Close();
  }
}

void WsClient::OnText(const std::string& payload) {
  if (callbacks_.on_text) callbacks_.on_text(payload);
}

void WsClient::OnBinary(const std::string& payload) {
  if (callbacks_.on_binary)
    callbacks_.on_binary(reinterpret_cast<const uint8_t*>(payload.data()),
                         payload.size());
}

bool WsClient::ConfigureTls(SSL_CTX* ctx) {
  if (!ConfigureTlsPeerName(ctx, uri_)) {
    LOG_ERROR("Unable to configure TLS peer identity");
    return false;
  }
  LoadTlsSystemRootCertificates(ctx);
  return true;
}

bool WsClient::OnTlsVerify(bool preverified, X509_STORE_CTX* store_ctx) {
  if (!preverified && VerifyTlsWithSystemTrust(store_ctx, uri_)) return true;
  if (!preverified) {
    LogTlsVerificationError(store_ctx);
    SetStatus(WsStatus::kTlsCertError);
  }
  return preverified;
}

}  // namespace minirtc
