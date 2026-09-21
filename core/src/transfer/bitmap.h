/*
 * CrossTransfer core — per-file received-block bitmap.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_TRANSFER_BITMAP_H_
#define CT_TRANSFER_BITMAP_H_

#include <cstddef>
#include <cstdint>
#include <vector>

#include "transfer/block_codec.h"

namespace ct {

class BlockBitmap {
 public:
  BlockBitmap() = default;
  explicit BlockBitmap(uint32_t block_count);

  void Reset(uint32_t block_count);
  uint32_t size() const { return size_; }
  uint32_t count() const { return count_; }
  bool Complete() const { return count_ == size_; }

  bool Test(uint32_t index) const;
  // Returns true if the bit was newly set. Out-of-range indices are ignored.
  bool Set(uint32_t index);

  // First unset index; equals size() when complete.
  uint32_t AckBase() const;

  // Unset runs at or after `from`, ascending, at most max_runs entries.
  std::vector<SackRun> Holes(uint32_t from, size_t max_runs) const;
  // Set runs, ascending, at most max_runs entries (for accept / persistence).
  std::vector<SackRun> HaveRuns(size_t max_runs) const;
  // Marks every block in the runs as received (ignores out-of-range parts).
  void SetRuns(const std::vector<SackRun>& runs);

 private:
  std::vector<uint64_t> words_;
  uint32_t size_ = 0;
  uint32_t count_ = 0;
  mutable uint32_t ack_base_ = 0;  // cached lower bound, advanced lazily
};

}  // namespace ct

#endif  // CT_TRANSFER_BITMAP_H_
