/*
 * Copyright (c) 2023-2026 by DI JUNKUN, All Rights Reserved.
 */

#ifndef MINIRTC_WS_CLIENT_H_
#define MINIRTC_WS_CLIENT_H_

#include <openssl/ssl.h>
#include <openssl/x509.h>

#include <atomic>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace minirtc {

enum class WsStatus {
  kConnecting = 0,
  kOpen,
  kFailed,
  kClosed,
  kReconnecting,
  kTlsCertError
};

const char* WsStatusName(WsStatus s);

class WsEndpoint;  // internal

// WebSocket client (ws:// and wss://) with automatic reconnect, ping keepalive
// and text + binary frames. Callbacks run on the I/O thread.
class WsClient : public std::enable_shared_from_this<WsClient> {
 public:
  struct Callbacks {
    std::function<void(const std::string&)> on_text;
    std::function<void(const uint8_t*, size_t)> on_binary;
    std::function<void(WsStatus)> on_status;
  };

  explicit WsClient(Callbacks callbacks);
  ~WsClient();

  int Connect(const std::string& uri);
  void Shutdown();

  bool SendText(const std::string& message);
  bool SendBinary(const uint8_t* data, size_t size);
  WsStatus Status() const { return status_.load(); }

  // --- used by WsEndpoint (internal) ---
  void OnOpen();
  void OnFail(const std::string& error, bool tls_error);
  void OnClose();
  void OnPong();
  void OnPongTimeout();
  void OnText(const std::string& payload);
  void OnBinary(const std::string& payload);
  bool OnTlsVerify(bool preverified, X509_STORE_CTX* store_ctx);
  void ConfigureTls(SSL_CTX* ctx);

 private:
  static void LoadTlsSystemRootCertificates(SSL_CTX* ssl_ctx);
  static bool VerifyTlsWithSystemTrust(X509_STORE_CTX* store_ctx,
                                       const std::string& uri);
  static bool LogTlsVerificationError(X509_STORE_CTX* store_ctx);

  void SetStatus(WsStatus status);
  void ScheduleReconnect();
  void StartEndpointLocked();
  void StopEndpoint(std::unique_ptr<WsEndpoint> endpoint);
  void PingLoop();

  Callbacks callbacks_;
  std::string uri_;
  bool secure_ = false;

  std::mutex mutex_;
  std::unique_ptr<WsEndpoint> endpoint_;
  std::thread io_thread_;
  std::thread ping_thread_;
  std::thread reconnect_thread_;
  std::vector<std::thread> old_threads_;
  std::condition_variable cv_;
  std::atomic<bool> shutdown_{false};
  std::atomic<bool> open_{false};
  std::atomic<WsStatus> status_{WsStatus::kClosed};
  std::atomic<int> reconnect_attempts_{0};
  std::atomic<int> pong_timeouts_{0};
  std::atomic<uint64_t> generation_{0};
};

}  // namespace minirtc

#endif
