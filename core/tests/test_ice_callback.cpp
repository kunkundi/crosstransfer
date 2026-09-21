#include <doctest/doctest.h>

#include <atomic>
#include <chrono>
#include <future>
#include <mutex>
#include <thread>
#include <vector>

#include "../../minirtc/src/ice/ice_agent.h"

TEST_CASE("ICE receive callback never holds the libjuice connection lock") {
  using namespace std::chrono;
  minirtc::IceConfig config;
  config.bind_address = "127.0.0.1";
  config.turn_mode = MINIRTC_TURN_DISABLED;
  std::mutex mutex;
  std::vector<std::string> a_candidates, b_candidates;
  std::atomic<bool> a_gathered{false}, b_gathered{false};
  std::atomic<bool> entered{false}, release{false}, exited{false};
  minirtc::IceAgent::Callbacks a_callbacks, b_callbacks;
  a_callbacks.on_candidate = [&](const std::string& value) {
    std::lock_guard<std::mutex> lock(mutex);
    a_candidates.push_back(value);
  };
  b_callbacks.on_candidate = [&](const std::string& value) {
    std::lock_guard<std::mutex> lock(mutex);
    b_candidates.push_back(value);
  };
  a_callbacks.on_gathering_done = [&] { a_gathered = true; };
  b_callbacks.on_gathering_done = [&] { b_gathered = true; };
  b_callbacks.on_recv = [&](const uint8_t*, size_t) {
    entered = true;
    // Model a slow upper-layer callback. A bounded wait also keeps a failed
    // assertion from leaving a test thread blocked during RAII destruction.
    const auto deadline = steady_clock::now() + seconds(3);
    while (!release && steady_clock::now() < deadline) std::this_thread::sleep_for(milliseconds(1));
    exited = true;
  };
  minirtc::IceAgent a(config, std::move(a_callbacks)), b(config, std::move(b_callbacks));
  REQUIRE(a.GatherCandidates() == 0);
  REQUIRE(b.GatherCandidates() == 0);
  const auto gather_deadline = steady_clock::now() + seconds(3);
  while ((!a_gathered || !b_gathered) && steady_clock::now() < gather_deadline) {
    std::this_thread::sleep_for(milliseconds(1));
  }
  REQUIRE(a_gathered);
  REQUIRE(b_gathered);
  REQUIRE(a.SetRemoteDescription(b.LocalDescription()) == 0);
  REQUIRE(b.SetRemoteDescription(a.LocalDescription()) == 0);
  {
    std::lock_guard<std::mutex> lock(mutex);
    REQUIRE_FALSE(a_candidates.empty());
    REQUIRE_FALSE(b_candidates.empty());
    for (const auto& value : a_candidates) REQUIRE(b.AddRemoteCandidate(value) == 0);
    for (const auto& value : b_candidates) REQUIRE(a.AddRemoteCandidate(value) == 0);
  }
  REQUIRE(a.SetRemoteGatheringDone() == 0);
  REQUIRE(b.SetRemoteGatheringDone() == 0);
  auto connected = [](minirtc::IceAgent& agent) {
    return agent.State() == minirtc::IceState::kConnected || agent.State() == minirtc::IceState::kCompleted;
  };
  const auto connect_deadline = steady_clock::now() + seconds(5);
  while ((!connected(a) || !connected(b)) && steady_clock::now() < connect_deadline) {
    std::this_thread::sleep_for(milliseconds(1));
  }
  REQUIRE(connected(a));
  REQUIRE(connected(b));
  const uint8_t payload = 42;
  REQUIRE(a.Send(&payload, 1) == 0);
  const auto receive_deadline = steady_clock::now() + seconds(2);
  while (!entered && steady_clock::now() < receive_deadline) std::this_thread::sleep_for(milliseconds(1));
  REQUIRE(entered);
  auto query = std::async(std::launch::async, [&] { return b.LocalDescription(); });
  const bool available = query.wait_for(milliseconds(200)) == std::future_status::ready;
  release = true;
  CHECK_FALSE(query.get().empty());
  CHECK(available);  // Old synchronous callback blocks juice_get_local_description.
  b.Close();
  CHECK(exited);  // Close waits for the last delivery callback.
  CHECK(b.Send(&payload, 1) == -1);
  b.Close();
}
