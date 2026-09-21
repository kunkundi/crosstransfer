#include <doctest/doctest.h>

#include <openssl/err.h>
#include <openssl/x509v3.h>

#include <memory>
#include <string>

#include "../../minirtc/src/ws/tls_peer_name.h"
#include "../../minirtc/src/ws/ws_client.h"

namespace {

using Certificate = std::shared_ptr<X509>;
using Key = std::shared_ptr<EVP_PKEY>;

Key MakeKey() {
  Key key(EVP_PKEY_Q_keygen(nullptr, nullptr, "EC", "prime256v1"), EVP_PKEY_free);
  REQUIRE(key);
  return key;
}

void AddExtension(X509* certificate, X509* issuer, int nid, const char* value) {
  X509V3_CTX context{};
  X509V3_set_ctx(&context, issuer, certificate, nullptr, nullptr, 0);
  std::unique_ptr<X509_EXTENSION, decltype(&X509_EXTENSION_free)> extension(
      X509V3_EXT_conf_nid(nullptr, &context, nid, value), X509_EXTENSION_free);
  REQUIRE(extension);
  REQUIRE(X509_add_ext(certificate, extension.get(), -1) == 1);
}

Certificate MakeCertificate(const Key& key, const Certificate& issuer,
                            const Key& issuer_key, const std::string& san,
                            bool expired = false) {
  Certificate certificate(X509_new(), X509_free);
  REQUIRE(certificate);
  REQUIRE(X509_set_version(certificate.get(), 2) == 1);
  REQUIRE(ASN1_INTEGER_set(X509_get_serialNumber(certificate.get()), issuer ? 2 : 1) == 1);
  REQUIRE(X509_set_pubkey(certificate.get(), key.get()) == 1);
  REQUIRE(X509_gmtime_adj(X509_getm_notBefore(certificate.get()), -3600));
  REQUIRE(X509_gmtime_adj(X509_getm_notAfter(certificate.get()), expired ? -60 : 3600));
  auto* subject = X509_get_subject_name(certificate.get());
  const char* name = issuer ? "files.test" : "CrossTransfer Test CA";
  REQUIRE(X509_NAME_add_entry_by_txt(subject, "CN", MBSTRING_ASC,
          reinterpret_cast<const unsigned char*>(name), -1, -1, 0) == 1);
  REQUIRE(X509_set_issuer_name(certificate.get(), issuer ? X509_get_subject_name(issuer.get()) : subject) == 1);
  X509* root = issuer ? issuer.get() : certificate.get();
  AddExtension(certificate.get(), root, NID_basic_constraints,
               issuer ? "critical,CA:FALSE" : "critical,CA:TRUE");
  AddExtension(certificate.get(), root, NID_key_usage,
               issuer ? "critical,digitalSignature" : "critical,keyCertSign,cRLSign");
  if (issuer) AddExtension(certificate.get(), root, NID_ext_key_usage, "serverAuth");
  if (!san.empty()) AddExtension(certificate.get(), root, NID_subject_alt_name, san.c_str());
  REQUIRE(X509_sign(certificate.get(), issuer_key.get(), EVP_sha256()) > 0);
  return certificate;
}

struct HandshakeResult { bool connected; long verification; };

HandshakeResult Handshake(const std::string& uri, const std::string& san,
                          bool trusted = true, bool expired = false) {
  auto root_key = MakeKey();
  auto root = MakeCertificate(root_key, {}, root_key, "");
  auto leaf_key = MakeKey();
  auto leaf = MakeCertificate(leaf_key, root, root_key, san, expired);
  std::unique_ptr<SSL_CTX, decltype(&SSL_CTX_free)> client_context(SSL_CTX_new(TLS_client_method()), SSL_CTX_free);
  std::unique_ptr<SSL_CTX, decltype(&SSL_CTX_free)> server_context(SSL_CTX_new(TLS_server_method()), SSL_CTX_free);
  REQUIRE(client_context);
  REQUIRE(server_context);
  REQUIRE(minirtc::ConfigureTlsPeerName(client_context.get(), uri));
  CHECK(SSL_CTX_get_min_proto_version(client_context.get()) == TLS1_2_VERSION);
  if (trusted) REQUIRE(X509_STORE_add_cert(SSL_CTX_get_cert_store(client_context.get()), root.get()) == 1);
  REQUIRE(SSL_CTX_use_certificate(server_context.get(), leaf.get()) == 1);
  REQUIRE(SSL_CTX_use_PrivateKey(server_context.get(), leaf_key.get()) == 1);
  REQUIRE(SSL_CTX_add1_chain_cert(server_context.get(), root.get()) == 1);
  std::unique_ptr<SSL, decltype(&SSL_free)> client(SSL_new(client_context.get()), SSL_free);
  std::unique_ptr<SSL, decltype(&SSL_free)> server(SSL_new(server_context.get()), SSL_free);
  REQUIRE(client);
  REQUIRE(server);
  BIO* client_bio = nullptr;
  BIO* server_bio = nullptr;
  REQUIRE(BIO_new_bio_pair(&client_bio, 0, &server_bio, 0) == 1);
  SSL_set_bio(client.get(), client_bio, client_bio);
  SSL_set_bio(server.get(), server_bio, server_bio);
  SSL_set_connect_state(client.get());
  SSL_set_accept_state(server.get());
  for (int attempt = 0; attempt < 100; ++attempt) {
    ERR_clear_error();
    int result = SSL_do_handshake(client.get());
    int error = SSL_get_error(client.get(), result);
    if (result != 1 && error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE)
      return {false, SSL_get_verify_result(client.get())};
    ERR_clear_error();
    result = SSL_do_handshake(server.get());
    error = SSL_get_error(server.get(), result);
    if (result != 1 && error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE)
      return {false, SSL_get_verify_result(client.get())};
    if (SSL_is_init_finished(client.get()) && SSL_is_init_finished(server.get()))
      return {true, SSL_get_verify_result(client.get())};
  }
  FAIL("Memory TLS handshake did not converge");
  return {false, -1};
}

}  // namespace

TEST_CASE("TLS authenticates DNS and numeric IP SAN identities during handshake") {
  const std::string san = "DNS:files.test,IP:127.0.0.1,IP:::1";
  CHECK(Handshake("wss://files.test:8443/ws", san).connected);
  CHECK(Handshake("wss://127.0.0.1/ws", san).connected);
  CHECK(Handshake("wss://[::1]:8443/ws", san).connected);
  const auto wrong_name = Handshake("wss://attacker.test/ws", san);
  CHECK_FALSE(wrong_name.connected);
  CHECK(wrong_name.verification == X509_V_ERR_HOSTNAME_MISMATCH);
  const auto wrong_ip = Handshake("wss://127.0.0.2/ws", san);
  CHECK_FALSE(wrong_ip.connected);
  CHECK(wrong_ip.verification == X509_V_ERR_IP_ADDRESS_MISMATCH);
  CHECK_FALSE(Handshake("wss://127.0.0.1/ws", "DNS:127.0.0.1").connected);
}

TEST_CASE("TLS requires trusted unexpired SAN certificates and bounded wildcards") {
  CHECK_FALSE(Handshake("wss://files.test/ws", "DNS:files.test", false).connected);
  const auto expired = Handshake("wss://files.test/ws", "DNS:files.test", true, true);
  CHECK_FALSE(expired.connected);
  CHECK(expired.verification == X509_V_ERR_CERT_HAS_EXPIRED);
  CHECK_FALSE(Handshake("wss://files.test/ws", "").connected);  // CN alone is insufficient.
  CHECK(Handshake("wss://files.example.test/ws", "DNS:*.example.test").connected);
  CHECK_FALSE(Handshake("wss://nested.files.example.test/ws", "DNS:*.example.test").connected);
  CHECK_FALSE(Handshake("wss://files.example.test/ws", "DNS:f*.example.test").connected);
}

TEST_CASE("TLS configuration fails closed and verification errors stop retries") {
  std::unique_ptr<SSL_CTX, decltype(&SSL_CTX_free)> context(SSL_CTX_new(TLS_client_method()), SSL_CTX_free);
  CHECK_FALSE(minirtc::ConfigureTlsPeerName(nullptr, "wss://files.test/ws"));
  for (const auto& uri : {"", "ws://files.test/ws", "wss:///ws", "wss://user@files.test/ws", "wss://[::1/ws"}) {
    CHECK_FALSE(minirtc::ConfigureTlsPeerName(context.get(), uri));
  }
  for (const int error : {X509_V_ERR_HOSTNAME_MISMATCH, X509_V_ERR_IP_ADDRESS_MISMATCH, X509_V_ERR_CERT_HAS_EXPIRED}) {
    minirtc::WsClient client({});
    std::unique_ptr<X509_STORE_CTX, decltype(&X509_STORE_CTX_free)> verification(X509_STORE_CTX_new(), X509_STORE_CTX_free);
    X509_STORE_CTX_set_error(verification.get(), error);
    CHECK_FALSE(client.OnTlsVerify(false, verification.get()));
    CHECK(client.Status() == minirtc::WsStatus::kTlsCertError);
    client.OnFail("TLS handshake failed", true);
    CHECK(client.Status() == minirtc::WsStatus::kTlsCertError);
  }
}
