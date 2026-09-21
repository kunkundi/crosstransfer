/*
 * CrossTransfer core — ctrl stream framing and message helpers.
 *
 * ctrl messages are UTF-8 JSON objects with a "type" field. They travel on
 * the reliable KCP stream. KCP limits one message to ~127 fragments, so a JSON
 * document is split into chunks of at most kCtrlChunk bytes, each prefixed by
 * one flag byte (0x01 = final chunk). Chunks of one message are contiguous
 * because the stream is ordered.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_TRANSFER_CTRL_CODEC_H_
#define CT_TRANSFER_CTRL_CODEC_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace ct {

// Splits a serialized message into wire chunks (each <= kCtrlChunk + 1).
std::vector<std::vector<uint8_t>> SplitCtrlMessage(const std::string& message);

class CtrlReassembler {
 public:
  // Feeds one wire chunk. Returns true when `message` now holds a complete
  // message. Returns false (and resets) on malformed input or if the message
  // would exceed kMaxCtrlMessage; *error is set in that case.
  bool Feed(const uint8_t* data, size_t len, std::string* message,
            std::string* error);
  void Reset();

 private:
  std::string buffer_;
};

// Parses a ctrl message; returns false if not a JSON object with a string
// "type".
bool ParseCtrlMessage(const std::string& message, nlohmann::json* out,
                      std::string* type);

}  // namespace ct

#endif  // CT_TRANSFER_CTRL_CODEC_H_
