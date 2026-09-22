#include <doctest/doctest.h>

#include "api/config.h"

TEST_CASE("service policy preserves preferences while handling legacy overrides") {
  ct::Config config;
  const ct::Config defaults;
  std::string error;
  REQUIRE(config.Merge({
      {"server", {{"host", "user-supplied.invalid"}, {"port", 12345},
                  {"tls", false}, {"path", "/other"}}},
      {"link_host", "user-links.invalid"},
      {"turn_mode", "force"}, {"ws_relay", "off"},
      {"enable_srtp", false}, {"enable_upnp", true}, {"ice_timeout_ms", 1},
      {"save_dir", "my-received-files"},
      {"share", {{"mode", "open"}, {"ttl_sec", 1234}}},
      {"service_available", false},
  }, &error));
  CHECK(config.save_dir == "my-received-files");
  CHECK(config.share_mode == "open");
  CHECK(config.share_ttl_sec == 1234);
  const auto snapshot = config.ToJson();
  CHECK(snapshot["service_available"] == true);
#if CT_DEVELOPER_MODE
  CHECK(config.server_host == "user-supplied.invalid");
  CHECK(config.server_port == 12345);
  CHECK(config.server_tls == false);
  CHECK(snapshot.contains("server"));
#else
  CHECK_FALSE(config.PeerAffectingDiff(defaults));
  CHECK(config.link_host == defaults.link_host);
  CHECK(config.server_tls);
  CHECK(config.server_port == 443);
  CHECK(config.server_path == "/ws");
  CHECK(config.enable_srtp);
  CHECK_FALSE(ct::Config::HasServiceOverrides(snapshot));
  // Even malformed obsolete settings must not block migration or disable service.
  CHECK(config.Merge({{"server", false}, {"turn_mode", 99}, {"link_host", 1}}, &error));
  CHECK_FALSE(config.PeerAffectingDiff(defaults));
  CHECK(config.link_host == defaults.link_host);
#endif
}

TEST_CASE("managed settings detection covers partial and null overrides") {
  for (const auto* key : {"server", "link_host", "turn_mode", "ws_relay",
                          "enable_srtp", "enable_upnp", "ice_timeout_ms"}) {
    CHECK(ct::Config::HasServiceOverrides({{key, nullptr}}));
  }
  CHECK_FALSE(ct::Config::HasServiceOverrides({{"save_dir", "received"},
      {"share", {{"ttl_sec", 600}}}}));
}
