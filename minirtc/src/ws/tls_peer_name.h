#ifndef MINIRTC_TLS_PEER_NAME_H_
#define MINIRTC_TLS_PEER_NAME_H_

#include <openssl/ssl.h>
#include <string>

namespace minirtc {
// Configure chain verification with a SAN identity and TLS >= 1.2. SNI alone
// does not authenticate the host. False means the connection must not proceed.
bool ConfigureTlsPeerName(SSL_CTX* ctx, const std::string& uri);
}

#endif
