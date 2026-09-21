#include <doctest/doctest.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <thread>

#define ASIO_STANDALONE
#include <asio/ip/tcp.hpp>

#include "../../minirtc/src/ws/ws_client.h"

TEST_CASE("WebSocket reconnect coexists with ping and shutdown interrupts backoff") {
  using namespace std::chrono;
  std::atomic<int> connections{0};
  std::atomic<int> retries{0};
  minirtc::WsClient::Callbacks callbacks;
  callbacks.on_status = [&](minirtc::WsStatus status) {
    if (status == minirtc::WsStatus::kConnecting) ++connections;
    if (status == minirtc::WsStatus::kReconnecting) ++retries;
  };
  auto client = std::make_shared<minirtc::WsClient>(std::move(callbacks));
  // Reserve a local port without listening. Real connection failures exercise
  // endpoint replacement while the ping thread is also waiting.
  asio::io_context context;
  asio::ip::tcp::acceptor reservation(context);
  reservation.open(asio::ip::tcp::v4());
  reservation.bind({asio::ip::address_v4::loopback(), 0});
  const auto uri = "ws://127.0.0.1:" +
                   std::to_string(reservation.local_endpoint().port()) + "/ws";
  REQUIRE(client->Connect(uri) == 0);
  // Darwin may time out each connect (5 s) instead of refusing immediately.
  const auto deadline = steady_clock::now() + seconds(25);
  while (retries.load() < 3 && steady_clock::now() < deadline) {
    std::this_thread::sleep_for(milliseconds(10));
  }
  CHECK(connections.load() >= 3);
  CHECK(retries.load() >= 3);
  const auto before = steady_clock::now();
  client->Shutdown();
  CHECK(steady_clock::now() - before < seconds(2));
  CHECK(client->Status() == minirtc::WsStatus::kClosed);
  CHECK(client->Connect(uri) == -1);
  client->Shutdown();  // idempotent after pending reconnect has been joined
}
