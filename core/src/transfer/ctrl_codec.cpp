/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "transfer/ctrl_codec.h"

#include "transfer/protocol.h"

#include <cstdint>

namespace ct {

std::vector<std::vector<uint8_t>> SplitCtrlMessage(const std::string& message) {
  std::vector<std::vector<uint8_t>> out;
  size_t offset = 0;
  do {
    const size_t n = std::min(kCtrlChunk, message.size() - offset);
    std::vector<uint8_t> chunk;
    chunk.reserve(n + 1);
    chunk.push_back(offset + n >= message.size() ? 0x01 : 0x00);
    chunk.insert(chunk.end(), message.begin() + static_cast<std::ptrdiff_t>(offset),
                 message.begin() + static_cast<std::ptrdiff_t>(offset + n));
    out.push_back(std::move(chunk));
    offset += n;
  } while (offset < message.size());
  return out;
}

bool CtrlReassembler::Feed(const uint8_t* data, size_t len, std::string* message,
                           std::string* error) {
  if (!data || len == 0) {
    if (error) *error = "empty ctrl chunk";
    Reset();
    return false;
  }
  if (data[0] > 0x01) {
    if (error) *error = "bad ctrl chunk flags";
    Reset();
    return false;
  }
  if (buffer_.size() + len - 1 > kMaxCtrlMessage) {
    if (error) *error = "ctrl message too large";
    Reset();
    return false;
  }
  buffer_.append(reinterpret_cast<const char*>(data) + 1, len - 1);
  if (data[0] == 0x01) {
    if (message) *message = std::move(buffer_);
    buffer_.clear();
    return true;
  }
  return false;
}

void CtrlReassembler::Reset() { buffer_.clear(); }

bool ParseCtrlMessage(const std::string& message, nlohmann::json* out,
                      std::string* type) {
  nlohmann::json j = nlohmann::json::parse(message, nullptr, false);
  if (!j.is_object()) return false;
  auto it = j.find("type");
  if (it == j.end() || !it->is_string()) return false;
  if (type) *type = it->get<std::string>();
  if (out) *out = std::move(j);
  return true;
}

}  // namespace ct
