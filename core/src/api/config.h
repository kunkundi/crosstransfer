/*
 * CrossTransfer core — configuration.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_API_CONFIG_H_
#define CT_API_CONFIG_H_

#include <string>

#include <nlohmann/json.hpp>

#include "runtime/peer.h"

namespace ct {

struct Config {
  Config();
  std::string data_dir;
  std::string log_dir;
  std::string log_level = "info";
  std::string server_host;
  int server_port = 443;
  bool server_tls = true;
  std::string server_path = "/ws";
  std::string link_host;
  std::string turn_mode = "auto";  // auto|force|off
  std::string ws_relay = "auto";   // auto|force|off
  bool enable_srtp = true;
  bool enable_upnp = false;
  int ice_timeout_ms = 15000;
  std::string save_dir;
  std::string share_mode = "once";
  int share_ttl_sec = 600;
  std::string app_version = "0.1.0";
  std::string platform;

  // Applies preferences. Infrastructure keys are accepted only in developer builds.
  // Unknown keys are ignored; wrong types set *error and return false.
  bool Merge(const nlohmann::json& j, std::string* error);
  static bool HasServiceOverrides(const nlohmann::json& j);
  nlohmann::json ToJson() const;
  // Everything needed to (re)create the signaling peer.
  PeerConfig ToPeerConfig() const;
  // True when a change to `other` requires a new peer.
  bool PeerAffectingDiff(const Config& other) const;
};

}  // namespace ct

#endif  // CT_API_CONFIG_H_
