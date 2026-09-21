/*
 * CrossTransfer core — data block and SACK datagram codecs.
 *
 * Block layout (network byte order):
 *   magic(2)=0x4342 ver(1) flags(1) file_index(2) block_index(4) len(2) payload[len]
 *
 * SACK layout:
 *   magic(2)=0x4353 ver(1) flags(1) file_index(2) run_count(2)
 *   ack_base(4) frontier(4) received_count(4) recv_rate_bps(4)
 *   loss_permille(2) reserved(2)
 *   runs[run_count]: start(4) length(4)      -- missing block ranges, ascending
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_TRANSFER_BLOCK_CODEC_H_
#define CT_TRANSFER_BLOCK_CODEC_H_

#include <cstddef>
#include <cstdint>
#include <vector>

#include "transfer/protocol.h"

namespace ct {

struct BlockHeader {
  uint8_t flags = 0;
  uint16_t file_index = 0;
  uint32_t block_index = 0;
  uint16_t len = 0;
};

// Writes header + payload into `out` (capacity out_cap). Returns bytes written
// or 0 if out_cap is too small or len > kBlockPayloadSize.
size_t EncodeBlock(const BlockHeader& h, const uint8_t* payload, uint8_t* out,
                   size_t out_cap);

// Parses a datagram. `*payload` points into `data`. Returns false on bad
// magic / version / length mismatch.
bool DecodeBlock(const uint8_t* data, size_t len, BlockHeader* h,
                 const uint8_t** payload);

// A run of consecutive block indices [start, start + length).
struct SackRun {
  uint32_t start = 0;
  uint32_t length = 0;
  bool operator==(const SackRun& o) const {
    return start == o.start && length == o.length;
  }
};

struct Sack {
  uint16_t file_index = 0;
  uint8_t flags = 0;
  uint32_t ack_base = 0;        // every block < ack_base has been received
  uint32_t frontier = 0;        // highest received block + 1 (0 = none yet)
  uint32_t received_count = 0;  // distinct blocks received so far
  uint32_t recv_rate_bps = 0;   // receiver-measured payload rate
  uint16_t loss_permille = 0;   // receiver loss estimate, 0..1000
  std::vector<SackRun> holes;   // missing runs in [ack_base, frontier), ascending
};

// Encodes at most kSackMaxRuns holes (the rest are dropped; the receiver keeps
// reporting them as ack_base advances).
std::vector<uint8_t> EncodeSack(const Sack& s);
bool DecodeSack(const uint8_t* data, size_t len, Sack* out);

}  // namespace ct

#endif  // CT_TRANSFER_BLOCK_CODEC_H_
