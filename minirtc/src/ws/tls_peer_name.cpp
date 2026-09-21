#include "tls_peer_name.h"

#include <asio/ip/address.hpp>
#include <openssl/x509v3.h>
#include <websocketpp/uri.hpp>

namespace minirtc {

bool ConfigureTlsPeerName(SSL_CTX* ctx, const std::string& uri) {
  if (!ctx || uri.rfind("wss://", 0) != 0 ||
      uri.find('\0') != std::string::npos) return false;
  const websocketpp::uri parsed(uri);
  if (!parsed.get_valid()) return false;
  const auto& host = parsed.get_host();
  if (host.empty() || host.find('@') != std::string::npos) return false;
  if (SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) != 1) return false;
  SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nullptr);
  auto* params = SSL_CTX_get0_param(ctx);
  if (!params) return false;
  X509_VERIFY_PARAM_set_hostflags(params, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS |
                                            X509_CHECK_FLAG_NEVER_CHECK_SUBJECT);
  asio::error_code error;
  asio::ip::make_address(host, error);
  if (!error) return X509_VERIFY_PARAM_set1_ip_asc(params, host.c_str()) == 1;
  return X509_VERIFY_PARAM_set1_host(params, host.data(), host.size()) == 1;
}

}  // namespace minirtc
