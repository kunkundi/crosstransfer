/*
 * Copyright (c) 2024-2026 by DI JUNKUN, All Rights Reserved.
 */

#include "minirtc.h"

#include <cstring>
#include <memory>
#include <string>

#include "log.h"
#include "peer_connection.h"

using minirtc::PeerConnection;
using minirtc::PeerParams;

struct MiniRtcPeer {
  std::unique_ptr<PeerConnection> pc;
};

namespace {

std::string S(const char* s, const char* def = "") { return s ? s : def; }

}  // namespace

extern "C" {

const char* minirtc_version(void) { return "1.0.0"; }

MiniRtcPeer* minirtc_create(const MiniRtcParams* p) {
  if (!p || !p->server_host) return nullptr;
  PeerParams pp;
  pp.server_host = p->server_host;
  pp.server_port = p->server_port;
  pp.server_tls = p->server_tls;
  pp.server_path = S(p->server_path, "/ws");
  pp.log_dir = S(p->log_dir, "logs");
  pp.turn_mode = p->turn_mode;
  pp.enable_srtp = p->enable_srtp;
  pp.enable_upnp = p->enable_upnp;
  pp.enable_ws_relay = p->enable_ws_relay;
  pp.force_ws_relay = p->force_ws_relay;
  pp.ice_timeout_ms = p->ice_timeout_ms > 0 ? p->ice_timeout_ms : 15000;
  pp.app = S(p->app, "crosstransfer");
  pp.version = S(p->version, "0");
  pp.platform = S(p->platform, "unknown");
  pp.on_signal_status = p->on_signal_status;
  pp.on_share_event = p->on_share_event;
  pp.on_claim_result = p->on_claim_result;
  pp.on_session_status = p->on_session_status;
  pp.on_receive_data = p->on_receive_data;
  pp.on_net_stats = p->on_net_stats;
  pp.user_data = p->user_data;
  minirtc::InitLogger(pp.log_dir);
  auto* peer = new MiniRtcPeer;
  peer->pc = std::make_unique<PeerConnection>(std::move(pp));
  return peer;
}

void minirtc_destroy(MiniRtcPeer** peer) {
  if (!peer || !*peer) return;
  (*peer)->pc->Disconnect();
  delete *peer;
  *peer = nullptr;
}

int minirtc_add_data_stream(MiniRtcPeer* peer, const char* name, bool reliable) {
  if (!peer || !name || !*name) return -1;
  return peer->pc->AddDataStream(name, reliable);
}

int minirtc_set_reliable_window(MiniRtcPeer* peer, const char* stream, int wnd) {
  if (!peer || !stream) return -1;
  return peer->pc->SetReliableWindow(stream, wnd);
}

int minirtc_connect(MiniRtcPeer* peer) {
  if (!peer) return -1;
  return peer->pc->Connect();
}

int minirtc_disconnect(MiniRtcPeer* peer) {
  if (!peer) return -1;
  return peer->pc->Disconnect();
}

int minirtc_create_share(MiniRtcPeer* peer, const char* mode, int ttl_sec,
                         const char* meta_json) {
  if (!peer) return -1;
  return peer->pc->CreateShare(S(mode, "once"), ttl_sec, S(meta_json));
}

int minirtc_close_share(MiniRtcPeer* peer, const char* share_id) {
  if (!peer || !share_id) return -1;
  return peer->pc->CloseShare(share_id);
}

int minirtc_claim(MiniRtcPeer* peer, const char* code, const char* resume_token) {
  if (!peer) return -1;
  const std::string c = S(code), t = S(resume_token);
  if (c.empty() && t.empty()) return -1;
  return peer->pc->Claim(c, t);
}

int minirtc_leave(MiniRtcPeer* peer, const char* session_id) {
  if (!peer || !session_id) return -1;
  return peer->pc->Leave(session_id);
}

int minirtc_send(MiniRtcPeer* peer, const char* session_id, const char* stream,
                 const void* data, size_t len) {
  if (!peer || !session_id || !stream || !data || len == 0) return -1;
  return peer->pc->Send(session_id, stream, static_cast<const uint8_t*>(data), len);
}

int minirtc_get_link_estimate(MiniRtcPeer* peer, const char* session_id,
                              MiniRtcLinkEstimate* out) {
  if (!peer || !session_id || !out) return -1;
  return peer->pc->GetLinkEstimate(session_id, out);
}

size_t minirtc_max_datagram_size(void) {
  return minirtc::DataTransport::kMaxDatagramPayload;
}

}  // extern "C"
