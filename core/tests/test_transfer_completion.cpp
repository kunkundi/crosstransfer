// Completion must keep the receiver alive until the sender has handled file_ok.
#include <doctest/doctest.h>

#include <chrono>
#include <filesystem>
#include <memory>
#include <random>
#include <thread>

#include "runtime/event_loop.h"
#include "runtime/peer.h"
#include "runtime/session_link.h"
#include "share/transfer_session.h"
#include "transfer/sha256.h"

namespace {
using namespace ct;

struct CompletionHarness {
  EventLoop loop;
  Peer peer{&loop, PeerConfig{}, {}};
  std::shared_ptr<SessionLink> link = std::make_shared<SessionLink>(&loop, &peer, "completion");
  std::shared_ptr<TransferSession> session;
  std::filesystem::path dir = std::filesystem::temp_directory_path() /
      ("ct_completion_" + std::to_string(std::random_device{}()));
  bool resume_cleared = false;
  int completions = 0;

  CompletionHarness() {
    std::filesystem::create_directories(dir);
    loop.Start();
    loop.RunSync([&] {
      TransferSession::Callbacks callbacks;
      callbacks.on_persist = [&](const nlohmann::json& value) { resume_cleared = value.is_null(); };
      callbacks.on_state = [&](const TransferSnapshot& value) {
        if (value.state == TransferState::kCompleted) ++completions;
      };
      session = std::make_shared<TransferSession>(&loop, link, "receive", "receiver", callbacks);
      TransferSession::ReceiverInput input;
      input.save_dir = dir;
      session->SetReceiverInput(std::move(input));
      session->OnTransportReady(MINIRTC_PATH_WS_RELAY);
      Manifest manifest;
      manifest.roots.push_back({"empty.bin", false});
      manifest.files.push_back({"empty.bin", 0});
      session->OnCtrlMessage(nlohmann::json{{"type", "offer"}, {"manifest", manifest.ToJson()}}.dump());
    });
    // The unattached link deliberately drops outgoing ctrl: the test decides
    // when the sender receives file_ok and replies, independently of timing.
  }

  ~CompletionHarness() {
    loop.RunSync([&] { session.reset(); });
    loop.Stop();
    std::filesystem::remove_all(dir);
  }

  void Ctrl(const nlohmann::json& message) {
    loop.RunSync([&] { session->OnCtrlMessage(message.dump()); });
  }

  TransferState State() {
    TransferState state;
    loop.RunSync([&] { state = session->state(); });
    return state;
  }

  void Verify() {
    Ctrl({{"type", "file_done"}, {"index", 0}, {"sha256", Sha256Hex("", 0)}});
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (State() == TransferState::kTransferring && std::chrono::steady_clock::now() < deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    REQUIRE(std::filesystem::exists(dir / "empty.bin"));
  }
};
}  // namespace

TEST_CASE("receiver completion waits for sender acknowledgement") {
  CompletionHarness h;
  h.Verify();
  CHECK(h.State() == TransferState::kVerifying);
  h.loop.RunSync([&] {
    CHECK_FALSE(h.resume_cleared);
    CHECK(h.completions == 0);
  });

  SUBCASE("transfer_done confirms file_ok arrived") {
    h.Ctrl({{"type", "transfer_done"}});
    h.Ctrl({{"type", "transfer_done"}}); // duplicate must not complete twice
  }
  SUBCASE("once sender closes its share before queued transfer_done arrives") {
    h.loop.RunSync([&] { h.session->OnSessionEnd("share_closed"); });
  }
  SUBCASE("completed open sender leaves before queued transfer_done arrives") {
    h.loop.RunSync([&] { h.session->OnSessionEnd("peer_left"); });
  }
  CHECK(h.State() == TransferState::kCompleted);
  h.loop.RunSync([&] {
    CHECK(h.resume_cleared);
    CHECK(h.completions == 1);
  });
}

TEST_CASE("sender completion cannot bypass local file verification") {
  CompletionHarness h;
  h.Ctrl({{"type", "transfer_done"}});
  CHECK(h.State() == TransferState::kTransferring);
  SUBCASE("local verification still completes") {
    h.Verify();
    CHECK(h.State() == TransferState::kCompleted);
  }
  SUBCASE("early close is a failure") {
    h.loop.RunSync([&] { h.session->OnSessionEnd("share_closed"); });
    CHECK(h.State() == TransferState::kFailed);
  }
}

TEST_CASE("unconfirmed receiver retains resume state on disconnect or cancellation") {
  CompletionHarness h;
  h.Verify();
  SUBCASE("unexpected disconnect remains resumable") {
    h.loop.RunSync([&] { h.session->OnSessionEnd("peer_offline"); });
    CHECK(h.State() == TransferState::kFailed);
    h.loop.RunSync([&] { CHECK_FALSE(h.resume_cleared); });
  }
  SUBCASE("late confirmation cannot undo cancellation") {
    h.loop.RunSync([&] { h.session->Cancel("user"); });
    h.Ctrl({{"type", "transfer_done"}});
    CHECK(h.State() == TransferState::kCancelled);
  }
}
