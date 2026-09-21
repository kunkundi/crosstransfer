/*
 * Copyright (c) 2025-2026 by DI JUNKUN, All Rights Reserved.
 */

#include "dtls_transport.h"

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>

#include <algorithm>
#include <cstring>
#include <iomanip>
#include <sstream>

#include "log.h"

namespace minirtc {

namespace {

void LogOpenSslErrors() {
  unsigned long e;
  while ((e = ERR_get_error()) != 0) {
    char buf[256];
    ERR_error_string_n(e, buf, sizeof(buf));
    LOG_ERROR("OpenSSL: {}", buf);
  }
}

// The peer certificate is self-signed; authentication is the SDP fingerprint.
int VerifyAlways(X509_STORE_CTX*, void*) { return 1; }

constexpr int kDtlsMtu = 1200;

}  // namespace

DtlsTransport::DtlsTransport() { GenerateCertificate(); }

DtlsTransport::~DtlsTransport() {
  Cleanup();
  if (pkey_) EVP_PKEY_free(pkey_);
  if (cert_) X509_free(cert_);
}

void DtlsTransport::Cleanup() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (ssl_) {
    SSL_free(ssl_);  // also frees bio_
    ssl_ = nullptr;
    bio_ = nullptr;
  }
  if (ctx_) {
    SSL_CTX_free(ctx_);
    ctx_ = nullptr;
  }
  std::queue<std::vector<uint8_t>> empty;
  incoming_.swap(empty);
}

BIO_METHOD* DtlsTransport::BioMethod() {
  static BIO_METHOD* m = [] {
    BIO_METHOD* method = BIO_meth_new(BIO_TYPE_SOURCE_SINK, "minirtc-dgram");
    BIO_meth_set_write(method, &DtlsTransport::BioWrite);
    BIO_meth_set_read(method, &DtlsTransport::BioRead);
    BIO_meth_set_create(method, &DtlsTransport::BioNew);
    BIO_meth_set_destroy(method, &DtlsTransport::BioFree);
    BIO_meth_set_ctrl(method, &DtlsTransport::BioCtrl);
    return method;
  }();
  return m;
}

int DtlsTransport::BioWrite(BIO* b, const char* buf, int len) {
  auto* self = static_cast<DtlsTransport*>(BIO_get_data(b));
  if (!self || !buf || len <= 0 || !self->send_) return -1;
  return self->send_(reinterpret_cast<const uint8_t*>(buf), (size_t)len) == 0
             ? len
             : -1;
}

int DtlsTransport::BioRead(BIO* b, char* buf, int len) {
  auto* self = static_cast<DtlsTransport*>(BIO_get_data(b));
  if (!self || !buf || len <= 0) return -1;
  // mutex_ is held by the caller of SSL_* functions.
  if (self->incoming_.empty()) {
    BIO_set_retry_read(b);
    return -1;
  }
  auto pkt = std::move(self->incoming_.front());
  self->incoming_.pop();
  const int n = std::min<int>(len, (int)pkt.size());
  std::memcpy(buf, pkt.data(), n);
  return n;
}

int DtlsTransport::BioNew(BIO* b) {
  BIO_set_init(b, 1);
  return 1;
}

int DtlsTransport::BioFree(BIO*) { return 1; }

long DtlsTransport::BioCtrl(BIO*, int cmd, long, void*) {
  switch (cmd) {
    case BIO_CTRL_FLUSH:
    case BIO_CTRL_DGRAM_SET_CONNECTED:
      return 1;
    case BIO_CTRL_DGRAM_QUERY_MTU:
    case BIO_CTRL_DGRAM_GET_MTU:
      return kDtlsMtu;
    default:
      return 0;
  }
}

void DtlsTransport::GenerateCertificate() {
  EVP_PKEY* pkey = EVP_PKEY_Q_keygen(nullptr, nullptr, "EC", "P-256");
  if (!pkey) {
    LOG_ERROR("EC keygen failed");
    LogOpenSslErrors();
    return;
  }
  X509* x509 = X509_new();
  if (!x509) {
    EVP_PKEY_free(pkey);
    return;
  }
  bool ok = ASN1_INTEGER_set(X509_get_serialNumber(x509), 1) == 1 &&
            X509_gmtime_adj(X509_getm_notBefore(x509), -60 * 60 * 24) &&
            X509_gmtime_adj(X509_getm_notAfter(x509),
                            60L * 60 * 24 * 365 * 10) &&
            X509_set_pubkey(x509, pkey) == 1;
  if (ok) {
    X509_NAME* name = X509_get_subject_name(x509);
    ok = X509_NAME_add_entry_by_txt(
             name, "CN", MBSTRING_ASC,
             reinterpret_cast<const unsigned char*>("CrossTransfer"), -1, -1,
             0) == 1 &&
         X509_set_issuer_name(x509, name) == 1 &&
         X509_sign(x509, pkey, EVP_sha256()) > 0;
  }
  if (!ok) {
    LOG_ERROR("Self-signed certificate generation failed");
    LogOpenSslErrors();
    X509_free(x509);
    EVP_PKEY_free(pkey);
    return;
  }
  pkey_ = pkey;
  cert_ = x509;
  fingerprint_ = Fingerprint(cert_);
}

std::string DtlsTransport::Fingerprint(X509* cert) {
  unsigned int n = 0;
  unsigned char md[EVP_MAX_MD_SIZE];
  if (X509_digest(cert, EVP_sha256(), md, &n) != 1) return {};
  std::ostringstream oss;
  for (unsigned int i = 0; i < n; ++i) {
    if (i) oss << ':';
    oss << std::uppercase << std::hex << std::setw(2) << std::setfill('0')
        << static_cast<int>(md[i]);
  }
  return oss.str();
}

bool DtlsTransport::IsDtlsRecord(const uint8_t* data, size_t len) {
  if (len < 13) return false;
  const uint8_t ct = data[0];
  if (ct < 20 || ct > 25) return false;
  return data[1] == 0xFE && (data[2] == 0xFF || data[2] == 0xFD);
}

int DtlsTransport::Start(bool is_client) {
  if (started_.exchange(true)) return 0;
  if (!cert_ || !pkey_) {
    LOG_ERROR("DTLS certificate missing");
    failed_ = true;
    return -1;
  }
  Done done = Done::kNone;
  {
  std::lock_guard<std::mutex> lock(mutex_);
  is_client_ = is_client;
  ctx_ = SSL_CTX_new(DTLS_method());
  if (!ctx_) {
    failed_ = true;
    return -1;
  }
  SSL_CTX_set_min_proto_version(ctx_, DTLS1_2_VERSION);
  if (SSL_CTX_set_tlsext_use_srtp(ctx_, "SRTP_AEAD_AES_128_GCM") != 0 ||
      SSL_CTX_use_certificate(ctx_, cert_) != 1 ||
      SSL_CTX_use_PrivateKey(ctx_, pkey_) != 1 ||
      SSL_CTX_check_private_key(ctx_) != 1) {
    LOG_ERROR("DTLS context setup failed");
    LogOpenSslErrors();
    failed_ = true;
    return -1;
  }
  SSL_CTX_set_verify(ctx_, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
                     nullptr);
  SSL_CTX_set_cert_verify_callback(ctx_, VerifyAlways, this);
  SSL_CTX_set_options(ctx_, SSL_OP_NO_QUERY_MTU);

  ssl_ = SSL_new(ctx_);
  if (!ssl_) {
    failed_ = true;
    return -1;
  }
  SSL_set_mtu(ssl_, kDtlsMtu);
  bio_ = BIO_new(BioMethod());
  BIO_set_data(bio_, this);
  SSL_set_bio(ssl_, bio_, bio_);
  if (is_client)
    SSL_set_connect_state(ssl_);
  else
    SSL_set_accept_state(ssl_);

  const int ret = SSL_do_handshake(ssl_);
  if (ret == 1) {
    done = CompleteHandshake();
  } else {
    const int err = SSL_get_error(ssl_, ret);
    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
      LOG_INFO("DTLS handshake started ({})", is_client ? "client" : "server");
    } else {
      LOG_ERROR("DTLS handshake start failed, err={}", err);
      LogOpenSslErrors();
      failed_ = true;
      done = Done::kFailed;
    }
  }
  }  // unlock
  Publish(done);
  return done == Done::kFailed ? -1 : 0;
}

void DtlsTransport::Publish(Done d) {
  if (d == Done::kNone || !done_) return;
  done_(d == Done::kVerified);
}

void DtlsTransport::Restart() {
  Cleanup();
  started_ = false;
  handshake_done_ = false;
  verified_ = false;
  failed_ = false;
}

bool DtlsTransport::HandleIncoming(const uint8_t* data, size_t len) {
  if (!IsDtlsRecord(data, len)) return false;
  Done done = Done::kNone;
  {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!ssl_) {
    // ClientHello may race the ICE connected callback; keep a small flight.
    if (incoming_.size() < 8) incoming_.emplace(data, data + len);
    return true;
  }
  incoming_.emplace(data, data + len);
  if (handshake_done_) {
    // Post-handshake records (alerts / rekeys). Drain to keep the BIO empty.
    char buf[64];
    while (!incoming_.empty()) {
      const int r = SSL_read(ssl_, buf, sizeof(buf));
      if (r <= 0) {
        const int err = SSL_get_error(ssl_, r);
        if (err == SSL_ERROR_ZERO_RETURN) {
          LOG_WARN("DTLS close_notify received");
        }
        break;
      }
    }
    std::queue<std::vector<uint8_t>> empty;
    incoming_.swap(empty);
    return true;
  }
  const int ret = SSL_do_handshake(ssl_);
  if (ret <= 0) {
    const int err = SSL_get_error(ssl_, ret);
    if (err != SSL_ERROR_WANT_READ && err != SSL_ERROR_WANT_WRITE) {
      LOG_ERROR("DTLS handshake failed, err={}", err);
      LogOpenSslErrors();
      failed_ = true;
      done = Done::kFailed;
    }
  } else if (SSL_is_init_finished(ssl_) && !handshake_done_) {
    done = CompleteHandshake();
  }
  }  // unlock
  Publish(done);
  return true;
}

void DtlsTransport::HandleTimeout() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!ssl_ || handshake_done_ || failed_) return;
  DTLSv1_handle_timeout(ssl_);
}

DtlsTransport::Done DtlsTransport::CompleteHandshake() {
  // mutex_ held.
  if (handshake_done_.exchange(true)) return Done::kNone;
  X509* peer = SSL_get1_peer_certificate(ssl_);
  if (!peer) {
    LOG_ERROR("DTLS peer certificate missing");
    failed_ = true;
    return Done::kFailed;
  }
  const std::string fp = Fingerprint(peer);
  X509_free(peer);
  if (remote_fingerprint_.empty() || fp != remote_fingerprint_) {
    LOG_ERROR("DTLS peer fingerprint mismatch");
    failed_ = true;
    return Done::kFailed;
  }
  verified_ = true;
  LOG_INFO("DTLS handshake complete, peer fingerprint verified");
  return Done::kVerified;
}

bool DtlsTransport::ExportSrtpKeys(std::vector<uint8_t>& local_key,
                                   std::vector<uint8_t>& local_salt,
                                   std::vector<uint8_t>& remote_key,
                                   std::vector<uint8_t>& remote_salt) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!verified_ || !ssl_) return false;
  const SRTP_PROTECTION_PROFILE* prof = SSL_get_selected_srtp_profile(ssl_);
  if (!prof || std::strcmp(prof->name, "SRTP_AEAD_AES_128_GCM") != 0) {
    LOG_ERROR("Unexpected SRTP profile");
    return false;
  }
  constexpr size_t kKey = 16, kSalt = 12;
  std::vector<uint8_t> material(2 * (kKey + kSalt));
  static const char kLabel[] = "EXTRACTOR-dtls_srtp";
  if (SSL_export_keying_material(ssl_, material.data(), material.size(), kLabel,
                                 sizeof(kLabel) - 1, nullptr, 0, 0) != 1) {
    LOG_ERROR("SSL_export_keying_material failed");
    return false;
  }
  // RFC 5764 §4.2: client key | server key | client salt | server salt.
  const uint8_t* client_key = material.data();
  const uint8_t* server_key = client_key + kKey;
  const uint8_t* client_salt = server_key + kKey;
  const uint8_t* server_salt = client_salt + kSalt;
  const uint8_t* lk = is_client_ ? client_key : server_key;
  const uint8_t* ls = is_client_ ? client_salt : server_salt;
  const uint8_t* rk = is_client_ ? server_key : client_key;
  const uint8_t* rs = is_client_ ? server_salt : client_salt;
  local_key.assign(lk, lk + kKey);
  local_salt.assign(ls, ls + kSalt);
  remote_key.assign(rk, rk + kKey);
  remote_salt.assign(rs, rs + kSalt);
  return true;
}

}  // namespace minirtc
