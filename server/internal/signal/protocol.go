// Package signal implements the CrossTransfer signaling protocol v1 over a
// single WebSocket endpoint. See docs/PLAN.md part three for the message table.
package signal

import "encoding/json"

// Protocol version accepted in hello.
const ProtoVersion = 1

// Envelope is the common shape of every JSON message.
type Envelope struct {
	Type string `json:"type"`
	ID   int64  `json:"id,omitempty"`
}

// Error codes.
const (
	CodeBadRequest     = "bad_request"
	CodeNotHello       = "hello_required"
	CodeUnsupported    = "unsupported_proto"
	CodeCodeNotFound   = "code_not_found"
	CodeCodeExpired    = "code_expired"
	CodeShareBusy      = "share_busy"
	CodeRateLimited    = "rate_limited"
	CodeShareNotFound  = "share_not_found"
	CodeSessionInvalid = "session_invalid"
	CodePeerOffline    = "peer_offline"
	CodeInternal       = "internal"
	CodeTooManyShares  = "too_many_shares"
)

// Session end / share close reasons.
const (
	ReasonPeerLeft     = "peer_left"
	ReasonPeerOffline  = "peer_offline"
	ReasonShareClosed  = "share_closed"
	ReasonShareExpired = "share_expired"
	ReasonServerClose  = "server_shutdown"
)

// ICEServer mirrors the WebRTC RTCIceServer dictionary.
type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
	ExpiresAt  int64    `json:"expires_at,omitempty"` // unix seconds, TURN only
}

// --- client → server ---

type HelloMsg struct {
	Envelope
	App      string `json:"app"`
	Version  string `json:"version"`
	Platform string `json:"platform"`
	Proto    int    `json:"proto"`
}

type CreateShareMsg struct {
	Envelope
	Mode   string          `json:"mode"`
	TTLSec int             `json:"ttl_sec"`
	Meta   json.RawMessage `json:"meta,omitempty"`
}

type CloseShareMsg struct {
	Envelope
	ShareID string `json:"share_id"`
}

type ClaimMsg struct {
	Envelope
	Code        string `json:"code"`
	ResumeToken string `json:"resume_token,omitempty"`
}

type SignalMsg struct {
	Envelope
	SessionID string          `json:"session_id"`
	To        string          `json:"to,omitempty"`
	From      string          `json:"from,omitempty"`
	Payload   json.RawMessage `json:"payload"`
}

type LeaveMsg struct {
	Envelope
	SessionID string `json:"session_id"`
}

// --- server → client ---

type WelcomeMsg struct {
	Envelope
	PeerID       string      `json:"peer_id"`
	ICEServers   []ICEServer `json:"ice_servers"`
	HeartbeatSec int         `json:"heartbeat_sec"`
	ServerTime   int64       `json:"server_time"`
}

type ShareCreatedMsg struct {
	Envelope
	ShareID   string `json:"share_id"`
	Code      string `json:"code"`         // canonical 10 chars
	CodeText  string `json:"code_display"` // XXXXX-XXXXX
	ExpiresAt int64  `json:"expires_at"`   // unix seconds
	Mode      string `json:"mode"`
}

type ShareClosedMsg struct {
	Envelope
	ShareID string `json:"share_id"`
	Reason  string `json:"reason"`
}

type SessionStartMsg struct {
	Envelope
	SessionID    string          `json:"session_id"`
	ShareID      string          `json:"share_id"`
	Role         string          `json:"role"` // "sender" | "receiver"
	RemotePeerID string          `json:"remote_peer_id"`
	ICEServers   []ICEServer     `json:"ice_servers"`
	ResumeToken  string          `json:"resume_token"`
	Resumed      bool            `json:"resumed"`
	Meta         json.RawMessage `json:"meta,omitempty"` // share meta, receiver only
}

type SessionEndMsg struct {
	Envelope
	SessionID string `json:"session_id"`
	Reason    string `json:"reason"`
}

type OKMsg struct {
	Envelope
}

type ErrorMsg struct {
	Envelope
	Code    string `json:"code"`
	Message string `json:"message"`
}

type PongMsg struct {
	Envelope
	ServerTime int64 `json:"server_time"`
}
