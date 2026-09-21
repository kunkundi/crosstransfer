#include <doctest/doctest.h>

#include "transfer/bitmap.h"

using namespace ct;

TEST_CASE("bitmap empty and single") {
  BlockBitmap empty(0);
  CHECK(empty.Complete());
  CHECK(empty.AckBase() == 0);
  CHECK(empty.Holes(0, 10).empty());

  BlockBitmap one(1);
  CHECK_FALSE(one.Complete());
  CHECK(one.AckBase() == 0);
  CHECK(one.Holes(0, 10) == std::vector<SackRun>{{0, 1}});
  CHECK(one.Set(0));
  CHECK_FALSE(one.Set(0));
  CHECK(one.Complete());
  CHECK(one.AckBase() == 1);
  CHECK(one.Holes(0, 10).empty());
  CHECK_FALSE(one.Set(1));  // out of range
}

TEST_CASE("bitmap ack base and holes across words") {
  BlockBitmap b(200);
  for (uint32_t i = 0; i < 70; ++i) b.Set(i);
  CHECK(b.AckBase() == 70);
  b.Set(71);
  b.Set(72);
  for (uint32_t i = 100; i < 130; ++i) b.Set(i);
  CHECK(b.count() == 70 + 2 + 30);
  const auto holes = b.Holes(0, 10);
  REQUIRE(holes.size() == 3);
  CHECK(holes[0] == SackRun{70, 1});
  CHECK(holes[1] == SackRun{73, 27});
  CHECK(holes[2] == SackRun{130, 70});
  CHECK(b.Holes(0, 1).size() == 1);
  CHECK(b.Holes(73, 10)[0] == SackRun{73, 27});
  const auto have = b.HaveRuns(10);
  REQUIRE(have.size() == 3);
  CHECK(have[0] == SackRun{0, 70});
  CHECK(have[1] == SackRun{71, 2});
  CHECK(have[2] == SackRun{100, 30});
  b.Set(70);
  CHECK(b.AckBase() == 73);
}

TEST_CASE("bitmap set runs and completion") {
  BlockBitmap b(130);
  b.SetRuns({{0, 64}, {64, 64}, {128, 100}});  // last run clipped
  CHECK(b.Complete());
  CHECK(b.AckBase() == 130);
  BlockBitmap c(10);
  c.SetRuns({{20, 5}});  // fully out of range
  CHECK(c.count() == 0);
  c.SetRuns(c.Holes(0, 100));
  CHECK(c.Complete());
}

TEST_CASE("bitmap reset") {
  BlockBitmap b(10);
  b.Set(3);
  b.Reset(5);
  CHECK(b.count() == 0);
  CHECK(b.size() == 5);
  CHECK(b.AckBase() == 0);
}
