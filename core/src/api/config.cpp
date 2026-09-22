/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "api/config.h"

namespace ct {
namespace {

template <typename T>
bool Take(const nlohmann::json& j, const char* key, T* out, std::string* error) {
  auto it = j.find(key);
  if (it == j.end() || it->is_null()) return true;
  try {
    *out = it->get<T>();
  } catch (const nlohmann::json::exception&) {
    if (error) *error = std::string("config.") + key + " has the wrong type";
    return false;
  }
  return true;
}

}  // namespace

Config::Config() {
  server_host = CT_SERVICE_HOST;
  link_host = CT_LINK_HOST;
#if CT_DEVELOPER_MODE
  if (server_host.empty()) {
    server_host = "127.0.0.1";
    server_port = 8080;
    server_tls = false;
  }
#endif
}

bool Config::HasServiceOverrides(const nlohmann::json& j) {
  for (const auto* key : {"server", "link_host", "turn_mode", "ws_relay",
                          "enable_srtp", "enable_upnp", "ice_timeout_ms"}) {
    if (j.contains(key)) return true;
  }
  return false;
}

bool Config::Merge(const nlohmann::json& j, std::string* error) {
  if (!j.is_object()) {
    if (error) *error = "config must be an object";
    return false;
  }
  if (!Take(j, "data_dir", &data_dir, error)) return false;
  if (!Take(j, "log_dir", &log_dir, error)) return false;
  if (!Take(j, "log_level", &log_level, error)) return false;
#if CT_DEVELOPER_MODE
  if (!Take(j, "link_host", &link_host, error)) return false;
  if (!Take(j, "turn_mode", &turn_mode, error)) return false;
  if (!Take(j, "ws_relay", &ws_relay, error)) return false;
  if (!Take(j, "enable_srtp", &enable_srtp, error)) return false;
  if (!Take(j, "enable_upnp", &enable_upnp, error)) return false;
  if (!Take(j, "ice_timeout_ms", &ice_timeout_ms, error)) return false;
#endif
  if (!Take(j, "save_dir", &save_dir, error)) return false;
  if (!Take(j, "app_version", &app_version, error)) return false;
  if (!Take(j, "platform", &platform, error)) return false;
#if CT_DEVELOPER_MODE
  auto server = j.find("server");
  if (server != j.end() && server->is_object()) {
    if (!Take(*server, "host", &server_host, error)) return false;
    if (!Take(*server, "port", &server_port, error)) return false;
    if (!Take(*server, "tls", &server_tls, error)) return false;
    if (!Take(*server, "path", &server_path, error)) return false;
  }
#endif
  auto share = j.find("share");
  if (share != j.end() && share->is_object()) {
    if (!Take(*share, "mode", &share_mode, error)) return false;
    if (!Take(*share, "ttl_sec", &share_ttl_sec, error)) return false;
  }
  if (turn_mode != "auto" && turn_mode != "force" && turn_mode != "off") {
    if (error) *error = "config.turn_mode must be auto|force|off";
    return false;
  }
  if (ws_relay != "auto" && ws_relay != "force" && ws_relay != "off") {
    if (error) *error = "config.ws_relay must be auto|force|off";
    return false;
  }
  if (share_mode != "once" && share_mode != "open") {
    if (error) *error = "config.share.mode must be once|open";
    return false;
  }
  if (server_path.empty()) server_path = "/ws";
  return true;
}

nlohmann::json Config::ToJson() const {
  nlohmann::json result = {
      {"data_dir", data_dir},
      {"log_dir", log_dir},
      {"log_level", log_level},
      {"service_available", !server_host.empty()},
      {"save_dir", save_dir},
      {"share", {{"mode", share_mode}, {"ttl_sec", share_ttl_sec}}},
      {"app_version", app_version},
      {"platform", platform},
  };
#if CT_DEVELOPER_MODE
  result.update({
      {"server", {{"host", server_host}, {"port", server_port}, {"tls", server_tls}, {"path", server_path}}},
      {"link_host", link_host},
      {"turn_mode", turn_mode},
      {"ws_relay", ws_relay},
      {"enable_srtp", enable_srtp},
      {"enable_upnp", enable_upnp},
      {"ice_timeout_ms", ice_timeout_ms},
  });
#endif
  return result;
}

PeerConfig Config::ToPeerConfig() const {
  PeerConfig p;
  p.server_host = server_host;
  p.server_port = server_port;
  p.server_tls = server_tls;
  p.server_path = server_path;
  p.log_dir = log_dir;
  p.turn_mode = turn_mode == "force" ? MINIRTC_TURN_FORCE
                : turn_mode == "off" ? MINIRTC_TURN_DISABLED
                                     : MINIRTC_TURN_AUTO;
  p.enable_srtp = enable_srtp;
  p.enable_upnp = enable_upnp;
  p.enable_ws_relay = ws_relay != "off";
  p.force_ws_relay = ws_relay == "force";
  p.ice_timeout_ms = ice_timeout_ms;
  p.app = "crosstransfer";
  p.version = app_version;
  p.platform = platform;
  return p;
}

bool Config::PeerAffectingDiff(const Config& o) const {
  return server_host != o.server_host || server_port != o.server_port ||
         server_tls != o.server_tls || server_path != o.server_path ||
         turn_mode != o.turn_mode || ws_relay != o.ws_relay || enable_srtp != o.enable_srtp ||
         enable_upnp != o.enable_upnp || ice_timeout_ms != o.ice_timeout_ms;
}

}  // namespace ct
