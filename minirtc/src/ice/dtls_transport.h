/*
 * Copyright (c) 2025-2026 by DI JUNKUN, All Rights Reserved.
 */

#ifndef MINIRTC_DTLS_TRANSPORT_H_
#define MINIRTC_DTLS_TRANSPORT_H_

#include <openssl/ssl.h>
#include <openssl/x509.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <queue>
#include <string>
#include <vector>

namespace minirtc {

// DTLS 1.2 handshake with SRTP key export (RFC 5764), running over any
// datagram path supplied by the owner. Independent of the ICE implementation
// so the same handshake also protects the WebSocket relay path.
class DtlsTransport {
 public:
  using SendFunc = std::function<int(const uint8_t*, size_t)>;
  using DoneFunc = std::function<void(bool verified)>;

  DtlsTransport();
  ~DtlsTransport();

  DtlsTransport(const DtlsTransport&) = delete;
  DtlsTransport& operator=(const DtlsTransport&) = delete;

  // "AB:CD:..." SHA-256 fingerprint of the local self-signed certificate.
  const std::string& LocalFingerprint() const { return fingerprint_; }
  void SetRemoteFingerprint(const std::string& fp) { remote_fingerprint_ = fp; }
  bool HasRemoteFingerprint() const { return !remote_fingerprint_.empty(); }

  void SetSendFunc(SendFunc f) { send_ = std::move(f); }
  void SetDoneFunc(DoneFunc f) { done_ = std::move(f); }

  // Starts the handshake; the client sends the first flight.
  int Start(bool is_client);
  // Abort any handshake in progress and allow Start() again with the same
  // certificate (used when the datagram path changes to the WS relay).
  void Restart();
  bool Started() const { return started_.load(); }
  bool Verified() const { return verified_.load(); }
  bool Failed() const { return failed_.load(); }

  static bool IsDtlsRecord(const uint8_t* data, size_t len);
  // Feed an incoming DTLS record. Returns true when the record was consumed.
  bool HandleIncoming(const uint8_t* data, size_t len);

  // Local/remote SRTP master key and salt for AES-128-GCM (16 + 12 bytes).
  bool ExportSrtpKeys(std::vector<uint8_t>& local_key,
                      std::vector<uint8_t>& local_salt,
                      std::vector<uint8_t>& remote_key,
                      std::vector<uint8_t>& remote_salt) const;

  // Retransmit handshake flights when the peer is silent (call periodically).
  void HandleTimeout();

 private:
  enum class Done { kNone, kVerified, kFailed };
  void GenerateCertificate();
  static std::string Fingerprint(X509* cert);
  // Called with mutex_ held; returns the event to publish after unlocking.
  Done CompleteHandshake();
  void Publish(Done d);
  void Cleanup();

  static BIO_METHOD* BioMethod();
  static int BioWrite(BIO* b, const char* buf, int len);
  static int BioRead(BIO* b, char* buf, int len);
  static int BioNew(BIO* b);
  static int BioFree(BIO* b);
  static long BioCtrl(BIO* b, int cmd, long num, void* ptr);

  SSL_CTX* ctx_ = nullptr;
  SSL* ssl_ = nullptr;
  BIO* bio_ = nullptr;
  EVP_PKEY* pkey_ = nullptr;
  X509* cert_ = nullptr;
  std::string fingerprint_;
  std::string remote_fingerprint_;
  bool is_client_ = false;

  SendFunc send_;
  DoneFunc done_;

  mutable std::mutex mutex_;
  std::queue<std::vector<uint8_t>> incoming_;
  std::atomic<bool> started_{false};
  std::atomic<bool> handshake_done_{false};
  std::atomic<bool> verified_{false};
  std::atomic<bool> failed_{false};
};

}  // namespace minirtc

#endif
