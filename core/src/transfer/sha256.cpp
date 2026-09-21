/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "transfer/sha256.h"

#include <openssl/evp.h>

#include <cstdio>
#include <vector>

namespace ct {
namespace {

std::string ToHex(const unsigned char* d, size_t n) {
  static const char* kHex = "0123456789abcdef";
  std::string out;
  out.resize(n * 2);
  for (size_t i = 0; i < n; ++i) {
    out[2 * i] = kHex[d[i] >> 4];
    out[2 * i + 1] = kHex[d[i] & 0xF];
  }
  return out;
}

}  // namespace

Sha256::Sha256() { Reset(); }

Sha256::~Sha256() {
  if (ctx_) EVP_MD_CTX_free(static_cast<EVP_MD_CTX*>(ctx_));
}

void Sha256::Reset() {
  if (!ctx_) ctx_ = EVP_MD_CTX_new();
  EVP_DigestInit_ex(static_cast<EVP_MD_CTX*>(ctx_), EVP_sha256(), nullptr);
}

void Sha256::Update(const void* data, size_t len) {
  if (len == 0) return;
  EVP_DigestUpdate(static_cast<EVP_MD_CTX*>(ctx_), data, len);
}

std::string Sha256::FinishHex() {
  unsigned char md[EVP_MAX_MD_SIZE];
  unsigned int n = 0;
  EVP_DigestFinal_ex(static_cast<EVP_MD_CTX*>(ctx_), md, &n);
  Reset();
  return ToHex(md, n);
}

std::string Sha256Hex(const void* data, size_t len) {
  Sha256 h;
  h.Update(data, len);
  return h.FinishHex();
}

bool Sha256File(const std::filesystem::path& path, std::string* hex,
                const std::function<bool()>& cancelled) {
  if (!hex) return false;
#ifdef _WIN32
  std::FILE* fp = _wfopen(path.c_str(), L"rb");
#else
  std::FILE* fp = std::fopen(path.c_str(), "rb");
#endif
  if (!fp) return false;
  std::vector<unsigned char> buf(1u << 20);
  Sha256 h;
  bool ok = true;
  for (;;) {
    if (cancelled && cancelled()) {
      ok = false;
      break;
    }
    const size_t n = std::fread(buf.data(), 1, buf.size(), fp);
    if (n > 0) h.Update(buf.data(), n);
    if (n < buf.size()) {
      ok = std::ferror(fp) == 0;
      break;
    }
  }
  std::fclose(fp);
  if (ok) *hex = h.FinishHex();
  return ok;
}

}  // namespace ct
