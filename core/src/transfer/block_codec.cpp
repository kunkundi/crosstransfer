/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "transfer/block_codec.h"

#include <cstdint>
#include <cstring>

namespace ct {
namespace {

inline void Put16(uint8_t* p, uint16_t v) {
  p[0] = static_cast<uint8_t>(v >> 8);
  p[1] = static_cast<uint8_t>(v);
}
inline void Put32(uint8_t* p, uint32_t v) {
  p[0] = static_cast<uint8_t>(v >> 24);
  p[1] = static_cast<uint8_t>(v >> 16);
  p[2] = static_cast<uint8_t>(v >> 8);
  p[3] = static_cast<uint8_t>(v);
}
inline uint16_t Get16(const uint8_t* p) {
  return static_cast<uint16_t>((p[0] << 8) | p[1]);
}
inline uint32_t Get32(const uint8_t* p) {
  return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
         (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}

}  // namespace

size_t EncodeBlock(const BlockHeader& h, const uint8_t* payload, uint8_t* out,
                   size_t out_cap) {
  if (h.len > kBlockPayloadSize) return 0;
  const size_t total = kBlockHeaderSize + h.len;
  if (out_cap < total || !out) return 0;
  if (h.len > 0 && !payload) return 0;
  Put16(out, kBlockMagic);
  out[2] = kProtoVersion;
  out[3] = h.flags;
  Put16(out + 4, h.file_index);
  Put32(out + 6, h.block_index);
  Put16(out + 10, h.len);
  if (h.len > 0) std::memcpy(out + kBlockHeaderSize, payload, h.len);
  return total;
}

bool DecodeBlock(const uint8_t* data, size_t len, BlockHeader* h,
                 const uint8_t** payload) {
  if (!data || !h || !payload || len < kBlockHeaderSize) return false;
  if (Get16(data) != kBlockMagic || data[2] != kProtoVersion) return false;
  const uint16_t plen = Get16(data + 10);
  if (plen > kBlockPayloadSize) return false;
  if (len != kBlockHeaderSize + plen) return false;
  h->flags = data[3];
  h->file_index = Get16(data + 4);
  h->block_index = Get32(data + 6);
  h->len = plen;
  *payload = data + kBlockHeaderSize;
  return true;
}

std::vector<uint8_t> EncodeSack(const Sack& s) {
  const size_t runs = s.holes.size() < kSackMaxRuns ? s.holes.size() : kSackMaxRuns;
  std::vector<uint8_t> out(kSackHeaderSize + runs * kSackRunSize);
  uint8_t* p = out.data();
  Put16(p, kSackMagic);
  p[2] = kProtoVersion;
  p[3] = s.flags;
  Put16(p + 4, s.file_index);
  Put16(p + 6, static_cast<uint16_t>(runs));
  Put32(p + 8, s.ack_base);
  Put32(p + 12, s.frontier);
  Put32(p + 16, s.received_count);
  Put32(p + 20, s.recv_rate_bps);
  Put16(p + 24, s.loss_permille);
  Put16(p + 26, 0);
  p += kSackHeaderSize;
  for (size_t i = 0; i < runs; ++i, p += kSackRunSize) {
    Put32(p, s.holes[i].start);
    Put32(p + 4, s.holes[i].length);
  }
  return out;
}

bool DecodeSack(const uint8_t* data, size_t len, Sack* out) {
  if (!data || !out || len < kSackHeaderSize) return false;
  if (Get16(data) != kSackMagic || data[2] != kProtoVersion) return false;
  const uint16_t runs = Get16(data + 6);
  if (len != kSackHeaderSize + static_cast<size_t>(runs) * kSackRunSize) return false;
  out->flags = data[3];
  out->file_index = Get16(data + 4);
  out->ack_base = Get32(data + 8);
  out->frontier = Get32(data + 12);
  out->received_count = Get32(data + 16);
  out->recv_rate_bps = Get32(data + 20);
  out->loss_permille = Get16(data + 24);
  out->holes.clear();
  out->holes.reserve(runs);
  const uint8_t* p = data + kSackHeaderSize;
  for (uint16_t i = 0; i < runs; ++i, p += kSackRunSize) {
    SackRun r;
    r.start = Get32(p);
    r.length = Get32(p + 4);
    if (r.length == 0) return false;
    out->holes.push_back(r);
  }
  return true;
}

}  // namespace ct
