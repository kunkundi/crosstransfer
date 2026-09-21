#include <doctest/doctest.h>

#include <atomic>
#include <chrono>
#include <thread>

#include "runtime/event_loop.h"

using namespace ct;

TEST_CASE("event loop ordering, delay, cancel, sync") {
  EventLoop loop("test");
  loop.Start();
  std::atomic<int> order{0};
  int a = 0, b = 0, c = 0;
  loop.Post([&] { a = ++order; });
  loop.Post([&] { b = ++order; });
  loop.RunSync([&] { c = ++order; });
  CHECK(a == 1);
  CHECK(b == 2);
  CHECK(c == 3);

  std::atomic<bool> fired{false};
  const auto id = loop.PostDelayed([&] { fired = true; }, 200);
  loop.Cancel(id);
  std::atomic<bool> fired2{false};
  const auto t0 = std::chrono::steady_clock::now();
  loop.PostDelayed([&] { fired2 = true; }, 30);
  while (!fired2.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  CHECK(std::chrono::steady_clock::now() - t0 >= std::chrono::milliseconds(30));
  std::this_thread::sleep_for(std::chrono::milliseconds(250));
  CHECK_FALSE(fired.load());

  bool current = false;
  loop.RunSync([&] { current = loop.IsCurrent(); });
  CHECK(current);
  CHECK_FALSE(loop.IsCurrent());
  loop.Stop();
  CHECK_FALSE(loop.Running());
}
