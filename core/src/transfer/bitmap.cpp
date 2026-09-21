/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "transfer/bitmap.h"

#include <algorithm>

namespace ct {

BlockBitmap::BlockBitmap(uint32_t block_count) { Reset(block_count); }

void BlockBitmap::Reset(uint32_t block_count) {
  size_ = block_count;
  count_ = 0;
  ack_base_ = 0;
  words_.assign((static_cast<size_t>(block_count) + 63) / 64, 0);
}

bool BlockBitmap::Test(uint32_t index) const {
  if (index >= size_) return false;
  return (words_[index / 64] >> (index % 64)) & 1u;
}

bool BlockBitmap::Set(uint32_t index) {
  if (index >= size_) return false;
  uint64_t& w = words_[index / 64];
  const uint64_t bit = 1ull << (index % 64);
  if (w & bit) return false;
  w |= bit;
  ++count_;
  return true;
}

uint32_t BlockBitmap::AckBase() const {
  uint32_t i = ack_base_;
  while (i < size_) {
    const size_t wi = i / 64;
    const uint64_t w = words_[wi];
    if (w == ~0ull) {
      i = static_cast<uint32_t>((wi + 1) * 64);
      continue;
    }
    // First zero bit at or after i inside this word.
    const uint64_t masked = ~w & (~0ull << (i % 64));
    if (masked == 0) {
      i = static_cast<uint32_t>((wi + 1) * 64);
      continue;
    }
#if defined(_MSC_VER)
    unsigned long idx;
    _BitScanForward64(&idx, masked);
    i = static_cast<uint32_t>(wi * 64 + idx);
#else
    i = static_cast<uint32_t>(wi * 64 + __builtin_ctzll(masked));
#endif
    break;
  }
  if (i > size_) i = size_;
  ack_base_ = i;
  return i;
}

std::vector<SackRun> BlockBitmap::Holes(uint32_t from, size_t max_runs) const {
  std::vector<SackRun> out;
  if (max_runs == 0) return out;
  uint32_t i = std::max(from, AckBase());
  while (i < size_ && out.size() < max_runs) {
    // Skip set bits.
    while (i < size_ && Test(i)) {
      if (i % 64 == 0 && words_[i / 64] == ~0ull) {
        i += 64;
      } else {
        ++i;
      }
    }
    if (i >= size_) break;
    const uint32_t start = i;
    while (i < size_ && !Test(i)) {
      if (i % 64 == 0 && words_[i / 64] == 0) {
        i += 64;
      } else {
        ++i;
      }
    }
    if (i > size_) i = size_;
    out.push_back({start, i - start});
  }
  return out;
}

std::vector<SackRun> BlockBitmap::HaveRuns(size_t max_runs) const {
  std::vector<SackRun> out;
  if (max_runs == 0) return out;
  uint32_t i = 0;
  while (i < size_ && out.size() < max_runs) {
    while (i < size_ && !Test(i)) {
      if (i % 64 == 0 && words_[i / 64] == 0) {
        i += 64;
      } else {
        ++i;
      }
    }
    if (i >= size_) break;
    const uint32_t start = i;
    while (i < size_ && Test(i)) {
      if (i % 64 == 0 && words_[i / 64] == ~0ull) {
        i += 64;
      } else {
        ++i;
      }
    }
    if (i > size_) i = size_;
    out.push_back({start, i - start});
  }
  return out;
}

void BlockBitmap::SetRuns(const std::vector<SackRun>& runs) {
  for (const auto& r : runs) {
    if (r.start >= size_) continue;
    const uint64_t end64 = static_cast<uint64_t>(r.start) + r.length;
    const uint32_t end = end64 > size_ ? size_ : static_cast<uint32_t>(end64);
    for (uint32_t i = r.start; i < end; ++i) Set(i);
  }
}

}  // namespace ct
