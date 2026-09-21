#include <doctest/doctest.h>

#include <cstring>
#include <vector>

#include "transfer/block_codec.h"

using namespace ct;

TEST_CASE("block round trip") {
  std::vector<uint8_t> payload(kBlockPayloadSize);
  for (size_t i = 0; i < payload.size(); ++i) payload[i] = static_cast<uint8_t>(i * 7);
  BlockHeader h;
  h.flags = kBlockFlagLast;
  h.file_index = 0xBEEF;
  h.block_index = 0xDEADBEEF;
  h.len = static_cast<uint16_t>(payload.size());
  uint8_t out[kMaxDatagram];
  const size_t n = EncodeBlock(h, payload.data(), out, sizeof(out));
  CHECK(n == kBlockHeaderSize + kBlockPayloadSize);
  CHECK(n <= kMaxDatagram);

  BlockHeader d;
  const uint8_t* p = nullptr;
  REQUIRE(DecodeBlock(out, n, &d, &p));
  CHECK(d.flags == h.flags);
  CHECK(d.file_index == h.file_index);
  CHECK(d.block_index == h.block_index);
  CHECK(d.len == h.len);
  CHECK(std::memcmp(p, payload.data(), payload.size()) == 0);
}

TEST_CASE("block zero-length payload") {
  BlockHeader h;
  h.len = 0;
  uint8_t out[kBlockHeaderSize];
  CHECK(EncodeBlock(h, nullptr, out, sizeof(out)) == kBlockHeaderSize);
  BlockHeader d;
  const uint8_t* p = nullptr;
  CHECK(DecodeBlock(out, kBlockHeaderSize, &d, &p));
  CHECK(d.len == 0);
}

TEST_CASE("block rejects bad input") {
  BlockHeader h;
  h.len = kBlockPayloadSize + 1;
  uint8_t out[kMaxDatagram];
  std::vector<uint8_t> big(kBlockPayloadSize + 1);
  CHECK(EncodeBlock(h, big.data(), out, sizeof(out)) == 0);
  h.len = 10;
  CHECK(EncodeBlock(h, big.data(), out, 5) == 0);  // too small
  const size_t n = EncodeBlock(h, big.data(), out, sizeof(out));
  REQUIRE(n == kBlockHeaderSize + 10);
  BlockHeader d;
  const uint8_t* p = nullptr;
  CHECK_FALSE(DecodeBlock(out, n - 1, &d, &p));  // length mismatch
  CHECK_FALSE(DecodeBlock(out, n + 1, &d, &p));
  CHECK_FALSE(DecodeBlock(out, kBlockHeaderSize - 1, &d, &p));
  out[0] ^= 0xFF;
  CHECK_FALSE(DecodeBlock(out, n, &d, &p));  // magic
  out[0] ^= 0xFF;
  out[2] = 99;
  CHECK_FALSE(DecodeBlock(out, n, &d, &p));  // version
  out[2] = kProtoVersion;
  out[10] = 0xFF;
  out[11] = 0xFF;
  CHECK_FALSE(DecodeBlock(out, n, &d, &p));  // len > payload size
}

TEST_CASE("sack round trip") {
  Sack s;
  s.file_index = 7;
  s.flags = kSackFlagComplete;
  s.ack_base = 1000;
  s.frontier = 2500;
  s.received_count = 950;
  s.recv_rate_bps = 12345678;
  s.loss_permille = 42;
  s.holes = {{1000, 3}, {1010, 1}, {2000, 500}};
  const auto buf = EncodeSack(s);
  CHECK(buf.size() == kSackHeaderSize + 3 * kSackRunSize);
  Sack d;
  REQUIRE(DecodeSack(buf.data(), buf.size(), &d));
  CHECK(d.file_index == 7);
  CHECK(d.flags == kSackFlagComplete);
  CHECK(d.ack_base == 1000);
  CHECK(d.frontier == 2500);
  CHECK(d.received_count == 950);
  CHECK(d.recv_rate_bps == 12345678);
  CHECK(d.loss_permille == 42);
  CHECK(d.holes == s.holes);
}

TEST_CASE("sack caps runs and rejects malformed") {
  Sack s;
  for (uint32_t i = 0; i < kSackMaxRuns + 50; ++i) s.holes.push_back({i * 2, 1});
  const auto buf = EncodeSack(s);
  CHECK(buf.size() <= kMaxDatagram);
  Sack d;
  REQUIRE(DecodeSack(buf.data(), buf.size(), &d));
  CHECK(d.holes.size() == kSackMaxRuns);

  CHECK_FALSE(DecodeSack(buf.data(), buf.size() - 1, &d));
  CHECK_FALSE(DecodeSack(buf.data(), kSackHeaderSize - 1, &d));
  auto bad = buf;
  bad[2] = 0;
  CHECK_FALSE(DecodeSack(bad.data(), bad.size(), &d));
  bad = buf;
  bad[6] = 0xFF;  // run_count larger than payload
  CHECK_FALSE(DecodeSack(bad.data(), bad.size(), &d));
  Sack zero;
  zero.holes = {{5, 0}};
  const auto zbuf = EncodeSack(zero);
  CHECK_FALSE(DecodeSack(zbuf.data(), zbuf.size(), &d));  // zero-length run
}
