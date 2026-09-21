/*
 * CrossTransfer core — SHA-256 (OpenSSL EVP).
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_TRANSFER_SHA256_H_
#define CT_TRANSFER_SHA256_H_

#include <cstddef>
#include <filesystem>
#include <functional>
#include <string>

namespace ct {

class Sha256 {
 public:
  Sha256();
  ~Sha256();
  Sha256(const Sha256&) = delete;
  Sha256& operator=(const Sha256&) = delete;

  void Reset();
  void Update(const void* data, size_t len);
  // Lower-case hex digest; the object is reset afterwards.
  std::string FinishHex();

 private:
  void* ctx_ = nullptr;  // EVP_MD_CTX*
};

std::string Sha256Hex(const void* data, size_t len);

// Streams the file through SHA-256. `cancelled` (optional) is polled between
// reads; returns false on I/O error or cancellation.
bool Sha256File(const std::filesystem::path& path, std::string* hex,
                const std::function<bool()>& cancelled = {});

}  // namespace ct

#endif  // CT_TRANSFER_SHA256_H_
