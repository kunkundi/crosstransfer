package signal

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"crosstransfer/server/internal/codes"
	"crosstransfer/server/internal/relay"
	"crosstransfer/server/internal/turn"
	"golang.org/x/time/rate"
)

// Sink is the outbound side of a peer connection. Implementations must be
// safe to call from any goroutine and must never block the hub for long.
type Sink interface {
	// SendText enqueues a JSON message.
	SendText(msg []byte)
	// SendBinary enqueues a relay frame.
	SendBinary(frame []byte)
	// Kick closes the connection with a reason.
	Kick(reason string)
}

// Options configures a Hub.
type Options struct {
	STUNURIs             []string
	TURNURI              string
	TURNSecret           string
	TURNCredTTL          time.Duration
	HeartbeatSec         int
	DefaultShareTTL      time.Duration
	MaxOnceTTL           time.Duration
	MaxOpenTTL           time.Duration
	MaxSharesPerPeer     int
	MaxSessions          int
	MaxSessionsPerPeer   int
	ClaimRatePerIP       float64
	ClaimBurstPerIP      int
	ClaimRateGlobal      float64
	ClaimBurstGlobal     int
	ClaimFailDelay       time.Duration
	RelayRateLimit       int // bytes/sec per connection
	RelayGlobalRateLimit int // aggregate bytes/sec, 0 disables
	Logger               *slog.Logger
	Now                  func() time.Time
	// Sleep is used to apply the constant failure delay; injectable for tests.
	Sleep func(time.Duration)
}

// Hub is the in-memory signaling state machine: peers, shares, sessions.
type Hub struct {
	opt          Options
	log          *slog.Logger
	mu           sync.Mutex
	peers        map[string]*Peer
	shares       map[string]*Share
	sessions     map[string]*Session
	tokens       map[string]*Session // resume token → session
	codes        *codes.Registry
	global       *rate.Limiter
	perIP        map[string]*ipLimiter
	stats        Stats
	closed       bool
	relayGlobal  *relay.Limiter
	queueDropped atomic.Uint64
}

// Stats is a snapshot of counters for /metrics and /healthz.
type Stats struct {
	Peers              int
	Shares             int
	Sessions           int
	ClaimsOK           uint64
	ClaimsFailed       uint64
	ClaimsLimited      uint64
	RelayFrames        uint64
	RelayBytes         uint64
	RelayDropped       uint64
	SignalForwards     uint64
	ConnectionsLimited uint64
	SessionsLimited    uint64
	RelayQueueDropped  uint64
}

type ipLimiter struct {
	lim      *rate.Limiter
	lastSeen time.Time
}

// Peer is one connected client.
type Peer struct {
	ID       string
	IP       string
	sink     Sink
	hello    bool
	app      string
	platform string
	shares   map[string]*Share
	sessions map[string]*Session
	relay    *relay.Limiter
	joined   time.Time
}

// Share is a registered take-code.
type Share struct {
	ID        string
	Code      string
	Mode      string // once | open
	Owner     *Peer
	Meta      json.RawMessage
	ExpiresAt time.Time
	Claimed   bool // once: code consumed
	sessions  map[string]*Session
}

// Session pairs a receiver with a share's sender.
type Session struct {
	ID          string
	Share       *Share
	Sender      *Peer
	Receiver    *Peer // nil while the receiver is offline (resumable)
	ResumeToken string
	CreatedAt   time.Time
}

// NewHub creates a hub.
func NewHub(o Options) *Hub {
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Sleep == nil {
		o.Sleep = time.Sleep
	}
	if o.HeartbeatSec <= 0 {
		o.HeartbeatSec = 30
	}
	if o.DefaultShareTTL <= 0 {
		o.DefaultShareTTL = 10 * time.Minute
	}
	if o.MaxOnceTTL <= 0 {
		o.MaxOnceTTL = 24 * time.Hour
	}
	if o.MaxOpenTTL <= 0 {
		o.MaxOpenTTL = 24 * time.Hour
	}
	if o.MaxSharesPerPeer <= 0 {
		o.MaxSharesPerPeer = 16
	}
	if o.MaxSessions <= 0 {
		o.MaxSessions = 4096
	}
	if o.MaxSessionsPerPeer <= 0 {
		o.MaxSessionsPerPeer = 64
	}
	if o.TURNCredTTL <= 0 {
		o.TURNCredTTL = 10 * time.Minute
	}
	h := &Hub{
		opt:         o,
		log:         o.Logger,
		peers:       make(map[string]*Peer),
		shares:      make(map[string]*Share),
		sessions:    make(map[string]*Session),
		tokens:      make(map[string]*Session),
		codes:       codes.NewRegistry(),
		perIP:       make(map[string]*ipLimiter),
		relayGlobal: relay.NewLimiter(o.RelayGlobalRateLimit),
	}
	if o.ClaimRateGlobal > 0 {
		h.global = rate.NewLimiter(rate.Limit(o.ClaimRateGlobal), max(o.ClaimBurstGlobal, 1))
	}
	return h
}

func randomID(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// Connect registers a new connection and returns its Peer. The peer must send
// hello before anything else.
func (h *Hub) Connect(ip string, sink Sink) *Peer {
	p := &Peer{
		ID:       randomID(8),
		IP:       ip,
		sink:     sink,
		shares:   make(map[string]*Share),
		sessions: make(map[string]*Session),
		relay:    relay.NewLimiter(h.opt.RelayRateLimit),
		joined:   h.opt.Now(),
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.peers[p.ID] = p
	return p
}

// Disconnect tears down everything the peer owns: its shares (notifying
// receivers) and its receiver-side sessions (notifying senders, but keeping
// the session resumable until the share expires).
func (h *Hub) Disconnect(p *Peer) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.peers[p.ID]; !ok {
		return
	}
	delete(h.peers, p.ID)
	for _, s := range p.shares {
		h.closeShareLocked(s, ReasonPeerOffline, p)
	}
	for _, sess := range p.sessions {
		if sess.Receiver == p {
			sess.Receiver = nil
			delete(p.sessions, sess.ID)
			if sess.Sender != nil {
				sess.Sender.send(SessionEndMsg{Envelope: Envelope{Type: "session_end"}, SessionID: sess.ID, Reason: ReasonPeerOffline})
			}
		}
	}
	h.log.Debug("peer disconnected", "peer", p.ID)
}

// Shutdown ends every session and share and kicks all peers.
func (h *Hub) Shutdown() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.closed = true
	for _, s := range h.shares {
		h.closeShareLocked(s, ReasonServerClose, nil)
	}
	for _, p := range h.peers {
		p.sink.Kick(ReasonServerClose)
	}
}

// Sweep expires shares whose TTL elapsed. Call periodically.
func (h *Hub) Sweep() int {
	now := h.opt.Now()
	h.mu.Lock()
	defer h.mu.Unlock()
	n := 0
	for _, s := range h.shares {
		if !now.Before(s.ExpiresAt) {
			h.closeShareLocked(s, ReasonShareExpired, nil)
			n++
		}
	}
	for ip, l := range h.perIP {
		if now.Sub(l.lastSeen) > 10*time.Minute {
			delete(h.perIP, ip)
		}
	}
	return n
}

// Stats returns a snapshot.
func (h *Hub) Stats() Stats {
	h.mu.Lock()
	defer h.mu.Unlock()
	st := h.stats
	st.Peers = len(h.peers)
	st.Shares = len(h.shares)
	st.Sessions = len(h.sessions)
	st.RelayQueueDropped = h.queueDropped.Load()
	return st
}

// HandleText processes one JSON message from p.
func (h *Hub) HandleText(p *Peer, data []byte) {
	var env Envelope
	if err := json.Unmarshal(data, &env); err != nil || env.Type == "" {
		p.sendError(0, CodeBadRequest, "malformed message")
		return
	}
	if !p.hello && env.Type != "hello" {
		p.sendError(env.ID, CodeNotHello, "hello required")
		return
	}
	switch env.Type {
	case "hello":
		h.onHello(p, env, data)
	case "create_share":
		h.onCreateShare(p, env, data)
	case "close_share":
		h.onCloseShare(p, env, data)
	case "claim":
		h.onClaim(p, env, data)
	case "signal":
		h.onSignal(p, env, data)
	case "leave":
		h.onLeave(p, env, data)
	case "ping":
		p.send(PongMsg{Envelope: Envelope{Type: "pong", ID: env.ID}, ServerTime: h.opt.Now().Unix()})
	case "pong":
		// keep-alive reply; nothing to do
	default:
		p.sendError(env.ID, CodeBadRequest, "unknown type "+env.Type)
	}
}

// HandleBinary forwards a relay frame from p to the other party of its session.
func (h *Hub) HandleBinary(p *Peer, frame []byte) {
	if !p.hello {
		return
	}
	sid, err := relay.ParseHeader(frame)
	if err != nil {
		p.sendError(0, CodeBadRequest, err.Error())
		return
	}
	h.mu.Lock()
	sess := h.sessions[sid]
	var dst *Peer
	if sess != nil {
		switch p {
		case sess.Sender:
			dst = sess.Receiver
		case sess.Receiver:
			dst = sess.Sender
		}
	}
	if sess == nil {
		// Frames in flight after a session ended are expected; do not answer
		// each one with an error (unreliable path, and avoids amplification).
		h.mu.Unlock()
		return
	}
	if sess.Sender != p && sess.Receiver != p {
		h.mu.Unlock()
		p.sendError(0, CodeSessionInvalid, "not a member of session")
		return
	}
	if dst == nil {
		h.mu.Unlock()
		return // peer offline; drop silently (unreliable path)
	}
	if !p.relay.Allow(len(frame), h.opt.Now()) || !h.relayGlobal.Allow(len(frame), h.opt.Now()) {
		h.stats.RelayDropped++
		h.mu.Unlock()
		return
	}
	h.stats.RelayFrames++
	h.stats.RelayBytes += uint64(len(frame))
	h.mu.Unlock()
	dst.sink.SendBinary(frame)
}

// --- handlers ---

func (h *Hub) onHello(p *Peer, env Envelope, data []byte) {
	var m HelloMsg
	if err := json.Unmarshal(data, &m); err != nil {
		p.sendError(env.ID, CodeBadRequest, err.Error())
		return
	}
	if m.Proto != ProtoVersion {
		p.sendError(env.ID, CodeUnsupported, fmt.Sprintf("proto %d unsupported, want %d", m.Proto, ProtoVersion))
		p.sink.Kick("unsupported proto")
		return
	}
	if p.hello {
		p.sendError(env.ID, CodeBadRequest, "hello already sent")
		return
	}
	h.mu.Lock()
	p.hello = true
	p.app = m.App
	p.platform = m.Platform
	h.mu.Unlock()
	p.send(WelcomeMsg{
		Envelope:     Envelope{Type: "welcome", ID: env.ID},
		PeerID:       p.ID,
		ICEServers:   h.iceServers(p.ID),
		HeartbeatSec: h.opt.HeartbeatSec,
		ServerTime:   h.opt.Now().Unix(),
	})
	h.log.Info("peer hello", "peer", p.ID, "app", m.App, "version", m.Version, "platform", m.Platform)
}

func (h *Hub) iceServers(peerID string) []ICEServer {
	var out []ICEServer
	if len(h.opt.STUNURIs) > 0 {
		out = append(out, ICEServer{URLs: h.opt.STUNURIs})
	}
	if h.opt.TURNURI != "" && h.opt.TURNSecret != "" {
		c := turn.IssueCredentials(h.opt.TURNSecret, peerID, h.opt.TURNCredTTL, h.opt.Now())
		out = append(out, ICEServer{URLs: []string{h.opt.TURNURI}, Username: c.Username, Credential: c.Password, ExpiresAt: c.ExpiresAt.Unix()})
	}
	if out == nil {
		out = []ICEServer{}
	}
	return out
}

func (h *Hub) onCreateShare(p *Peer, env Envelope, data []byte) {
	var m CreateShareMsg
	if err := json.Unmarshal(data, &m); err != nil {
		p.sendError(env.ID, CodeBadRequest, err.Error())
		return
	}
	mode := strings.ToLower(m.Mode)
	if mode == "" {
		mode = "once"
	}
	if mode != "once" && mode != "open" {
		p.sendError(env.ID, CodeBadRequest, "mode must be once or open")
		return
	}
	ttl := h.opt.DefaultShareTTL
	if m.TTLSec > 0 {
		ttl = time.Duration(m.TTLSec) * time.Second
	}
	maxTTL := h.opt.MaxOnceTTL
	if mode == "open" {
		maxTTL = h.opt.MaxOpenTTL
	}
	if ttl > maxTTL {
		ttl = maxTTL
	}
	if len(m.Meta) > 16*1024 {
		p.sendError(env.ID, CodeBadRequest, "meta too large")
		return
	}
	now := h.opt.Now()
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}
	if len(p.shares) >= h.opt.MaxSharesPerPeer {
		h.mu.Unlock()
		p.sendError(env.ID, CodeTooManyShares, "too many shares on this connection")
		return
	}
	s := &Share{
		ID:        randomID(8),
		Mode:      mode,
		Owner:     p,
		Meta:      m.Meta,
		ExpiresAt: now.Add(ttl),
		sessions:  make(map[string]*Session),
	}
	entry, err := h.codes.Add(s.ID, s.ExpiresAt)
	if err != nil {
		h.mu.Unlock()
		p.sendError(env.ID, CodeInternal, "code allocation failed")
		return
	}
	s.Code = entry.Code
	h.shares[s.ID] = s
	p.shares[s.ID] = s
	h.mu.Unlock()
	p.send(ShareCreatedMsg{
		Envelope:  Envelope{Type: "share_created", ID: env.ID},
		ShareID:   s.ID,
		Code:      s.Code,
		CodeText:  codes.Format(s.Code),
		ExpiresAt: s.ExpiresAt.Unix(),
		Mode:      mode,
	})
	h.log.Info("share created", "peer", p.ID, "share", s.ID, "mode", mode, "code", codes.LogPrefix(s.Code), "ttl", ttl)
}

func (h *Hub) onCloseShare(p *Peer, env Envelope, data []byte) {
	var m CloseShareMsg
	if err := json.Unmarshal(data, &m); err != nil {
		p.sendError(env.ID, CodeBadRequest, err.Error())
		return
	}
	h.mu.Lock()
	s := h.shares[m.ShareID]
	if s == nil || s.Owner != p {
		h.mu.Unlock()
		p.sendError(env.ID, CodeShareNotFound, "share not found")
		return
	}
	h.closeShareLocked(s, ReasonShareClosed, p)
	h.mu.Unlock()
	p.send(OKMsg{Envelope{Type: "ok", ID: env.ID}})
}

// closeShareLocked removes the share, its code and all its sessions. Every
// connected receiver gets session_end{reason}; the owner gets share_closed
// unless it initiated the close or is the one going offline.
func (h *Hub) closeShareLocked(s *Share, reason string, initiator *Peer) {
	if _, ok := h.shares[s.ID]; !ok {
		return
	}
	delete(h.shares, s.ID)
	h.codes.Remove(s.ID)
	if s.Owner != nil {
		delete(s.Owner.shares, s.ID)
	}
	for _, sess := range s.sessions {
		h.endSessionLocked(sess, reason, initiator)
	}
	if s.Owner != nil && s.Owner != initiator && reason != ReasonPeerOffline {
		s.Owner.send(ShareClosedMsg{Envelope: Envelope{Type: "share_closed"}, ShareID: s.ID, Reason: reason})
	}
	h.log.Info("share closed", "share", s.ID, "reason", reason)
}

// endSessionLocked removes a session entirely and notifies both parties
// except `initiator`.
func (h *Hub) endSessionLocked(sess *Session, reason string, initiator *Peer) {
	if _, ok := h.sessions[sess.ID]; !ok {
		return
	}
	delete(h.sessions, sess.ID)
	delete(h.tokens, sess.ResumeToken)
	delete(sess.Share.sessions, sess.ID)
	msg := SessionEndMsg{Envelope: Envelope{Type: "session_end"}, SessionID: sess.ID, Reason: reason}
	for _, p := range []*Peer{sess.Sender, sess.Receiver} {
		if p == nil {
			continue
		}
		delete(p.sessions, sess.ID)
		if p != initiator {
			p.send(msg)
		}
	}
}

func (h *Hub) claimAllowed(ip string) bool {
	now := h.opt.Now()
	if h.global != nil && !h.global.AllowN(now, 1) {
		return false
	}
	if h.opt.ClaimRatePerIP <= 0 {
		return true
	}
	l := h.perIP[ip]
	if l == nil {
		l = &ipLimiter{lim: rate.NewLimiter(rate.Limit(h.opt.ClaimRatePerIP), max(h.opt.ClaimBurstPerIP, 1))}
		h.perIP[ip] = l
	}
	l.lastSeen = now
	return l.lim.AllowN(now, 1)
}

func (h *Hub) onClaim(p *Peer, env Envelope, data []byte) {
	var m ClaimMsg
	if err := json.Unmarshal(data, &m); err != nil {
		p.sendError(env.ID, CodeBadRequest, err.Error())
		return
	}
	now := h.opt.Now()

	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}
	if !h.claimAllowed(p.IP) {
		h.stats.ClaimsLimited++
		h.mu.Unlock()
		h.opt.Sleep(h.opt.ClaimFailDelay)
		p.sendError(env.ID, CodeRateLimited, "too many claims")
		return
	}

	// Resume path: token identifies an existing session whose receiver left.
	if m.ResumeToken != "" {
		sess := h.tokens[m.ResumeToken]
		if sess == nil {
			h.stats.ClaimsFailed++
			h.mu.Unlock()
			h.opt.Sleep(h.opt.ClaimFailDelay)
			p.sendError(env.ID, CodeCodeNotFound, "resume token unknown")
			return
		}
		if sess.Receiver != nil {
			h.stats.ClaimsFailed++
			h.mu.Unlock()
			h.opt.Sleep(h.opt.ClaimFailDelay)
			p.sendError(env.ID, CodeShareBusy, "session already has a receiver")
			return
		}
		if len(p.sessions) >= h.opt.MaxSessionsPerPeer {
			h.stats.SessionsLimited++
			h.mu.Unlock()
			p.sendError(env.ID, CodeServerBusy, "session capacity reached")
			return
		}
		sess.Receiver = p
		p.sessions[sess.ID] = sess
		h.stats.ClaimsOK++
		h.mu.Unlock()
		h.announceSession(sess, env.ID, true)
		h.log.Info("session resumed", "session", sess.ID, "share", sess.Share.ID, "receiver", p.ID)
		return
	}

	entry, err := h.codes.Lookup(m.Code, now)
	if err != nil {
		h.stats.ClaimsFailed++
		h.mu.Unlock()
		h.opt.Sleep(h.opt.ClaimFailDelay)
		code := CodeCodeNotFound
		if errors.Is(err, codes.ErrExpired) {
			code = CodeCodeExpired
		}
		p.sendError(env.ID, code, "take-code rejected")
		h.log.Info("claim failed", "peer", p.ID, "code", codes.LogPrefix(m.Code), "err", err)
		return
	}
	s := h.shares[entry.ID]
	if s == nil || s.Owner == nil {
		h.stats.ClaimsFailed++
		h.mu.Unlock()
		h.opt.Sleep(h.opt.ClaimFailDelay)
		p.sendError(env.ID, CodeCodeNotFound, "take-code rejected")
		return
	}
	if s.Owner == p {
		h.mu.Unlock()
		p.sendError(env.ID, CodeBadRequest, "cannot claim own share")
		return
	}
	if len(h.sessions) >= h.opt.MaxSessions || len(p.sessions) >= h.opt.MaxSessionsPerPeer ||
		len(s.Owner.sessions) >= h.opt.MaxSessionsPerPeer {
		h.stats.SessionsLimited++
		h.mu.Unlock()
		p.sendError(env.ID, CodeServerBusy, "session capacity reached")
		return
	}
	sess := &Session{
		ID:          randomID(8),
		Share:       s,
		Sender:      s.Owner,
		Receiver:    p,
		ResumeToken: randomID(16),
		CreatedAt:   now,
	}
	h.sessions[sess.ID] = sess
	h.tokens[sess.ResumeToken] = sess
	s.sessions[sess.ID] = sess
	s.Owner.sessions[sess.ID] = sess
	p.sessions[sess.ID] = sess
	if s.Mode == "once" {
		// Code is consumed; the share (and its session) live on for resume.
		s.Claimed = true
		h.codes.Remove(s.ID)
	}
	h.stats.ClaimsOK++
	h.mu.Unlock()
	h.announceSession(sess, env.ID, false)
	h.log.Info("session started", "session", sess.ID, "share", s.ID, "sender", sess.Sender.ID, "receiver", p.ID, "mode", s.Mode)
}

// announceSession sends session_start to both parties. reqID is the
// receiver's claim request id.
func (h *Hub) announceSession(sess *Session, reqID int64, resumed bool) {
	h.mu.Lock()
	sender, receiver := sess.Sender, sess.Receiver
	share := sess.Share
	h.mu.Unlock()
	if receiver != nil {
		receiver.send(SessionStartMsg{
			Envelope:     Envelope{Type: "session_start", ID: reqID},
			SessionID:    sess.ID,
			ShareID:      share.ID,
			Role:         "receiver",
			RemotePeerID: sender.ID,
			ICEServers:   h.iceServers(receiver.ID),
			ResumeToken:  sess.ResumeToken,
			Resumed:      resumed,
			Meta:         share.Meta,
		})
	}
	if sender != nil {
		sender.send(SessionStartMsg{
			Envelope:     Envelope{Type: "session_start"},
			SessionID:    sess.ID,
			ShareID:      share.ID,
			Role:         "sender",
			RemotePeerID: receiver.ID,
			ICEServers:   h.iceServers(sender.ID),
			ResumeToken:  sess.ResumeToken,
			Resumed:      resumed,
		})
	}
}

func (h *Hub) onSignal(p *Peer, env Envelope, data []byte) {
	var m SignalMsg
	if err := json.Unmarshal(data, &m); err != nil {
		p.sendError(env.ID, CodeBadRequest, err.Error())
		return
	}
	if len(m.Payload) == 0 {
		p.sendError(env.ID, CodeBadRequest, "payload required")
		return
	}
	h.mu.Lock()
	sess := h.sessions[m.SessionID]
	var dst *Peer
	if sess != nil {
		switch p {
		case sess.Sender:
			dst = sess.Receiver
		case sess.Receiver:
			dst = sess.Sender
		default:
			sess = nil
		}
	}
	if sess == nil {
		h.mu.Unlock()
		p.sendError(env.ID, CodeSessionInvalid, "not a member of session")
		return
	}
	if dst == nil {
		h.mu.Unlock()
		p.sendError(env.ID, CodePeerOffline, "peer offline")
		return
	}
	if m.To != "" && m.To != dst.ID {
		h.mu.Unlock()
		p.sendError(env.ID, CodeBadRequest, "to does not match session peer")
		return
	}
	h.stats.SignalForwards++
	h.mu.Unlock()
	dst.send(SignalMsg{
		Envelope:  Envelope{Type: "signal"},
		SessionID: sess.ID,
		From:      p.ID,
		To:        dst.ID,
		Payload:   m.Payload,
	})
	if env.ID != 0 {
		p.send(OKMsg{Envelope{Type: "ok", ID: env.ID}})
	}
}

func (h *Hub) onLeave(p *Peer, env Envelope, data []byte) {
	var m LeaveMsg
	if err := json.Unmarshal(data, &m); err != nil {
		p.sendError(env.ID, CodeBadRequest, err.Error())
		return
	}
	h.mu.Lock()
	sess := h.sessions[m.SessionID]
	if sess == nil || (sess.Sender != p && sess.Receiver != p) {
		h.mu.Unlock()
		p.sendError(env.ID, CodeSessionInvalid, "not a member of session")
		return
	}
	h.endSessionLocked(sess, ReasonPeerLeft, p)
	h.mu.Unlock()
	p.send(OKMsg{Envelope{Type: "ok", ID: env.ID}})
	h.log.Info("session left", "session", sess.ID, "peer", p.ID)
}

// --- peer helpers ---

func (p *Peer) send(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	p.sink.SendText(b)
}

func (p *Peer) sendError(id int64, code, msg string) {
	p.send(ErrorMsg{Envelope: Envelope{Type: "error", ID: id}, Code: code, Message: msg})
}
