package signal

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"crosstransfer/server/internal/codes"
	"crosstransfer/server/internal/relay"
)

// fakeSink records everything the hub sends to a peer.
type fakeSink struct {
	mu     sync.Mutex
	texts  []map[string]any
	bins   [][]byte
	kicked string
}

func (f *fakeSink) SendText(b []byte) {
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		panic(err)
	}
	f.mu.Lock()
	f.texts = append(f.texts, m)
	f.mu.Unlock()
}
func (f *fakeSink) SendBinary(b []byte) {
	f.mu.Lock()
	f.bins = append(f.bins, append([]byte{}, b...))
	f.mu.Unlock()
}
func (f *fakeSink) Kick(r string) { f.mu.Lock(); f.kicked = r; f.mu.Unlock() }

// pop returns and removes the first queued text message.
func (f *fakeSink) pop(t *testing.T) map[string]any {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.texts) == 0 {
		t.Fatal("no message queued")
	}
	m := f.texts[0]
	f.texts = f.texts[1:]
	return m
}

func (f *fakeSink) count() int { f.mu.Lock(); defer f.mu.Unlock(); return len(f.texts) }

func expect(t *testing.T, m map[string]any, typ string) map[string]any {
	t.Helper()
	if m["type"] != typ {
		t.Fatalf("want %s, got %v", typ, m)
	}
	return m
}

type env struct {
	hub   *Hub
	now   time.Time
	slept []time.Duration
}

func newEnv(t *testing.T, mutate func(*Options)) *env {
	e := &env{now: time.Unix(1_800_000_000, 0)}
	o := Options{
		STUNURIs:         []string{"stun:1.2.3.4:3478"},
		TURNURI:          "turn:1.2.3.4:3478?transport=udp",
		TURNSecret:       "secret",
		HeartbeatSec:     30,
		DefaultShareTTL:  10 * time.Minute,
		ClaimRatePerIP:   100,
		ClaimBurstPerIP:  100,
		ClaimRateGlobal:  1000,
		ClaimBurstGlobal: 1000,
		ClaimFailDelay:   250 * time.Millisecond,
		Now:              func() time.Time { return e.now },
		Sleep:            func(d time.Duration) { e.slept = append(e.slept, d) },
	}
	if mutate != nil {
		mutate(&o)
	}
	e.hub = NewHub(o)
	return e
}

func (e *env) connect(t *testing.T, ip string) (*Peer, *fakeSink) {
	t.Helper()
	s := &fakeSink{}
	p := e.hub.Connect(ip, s)
	e.hub.HandleText(p, []byte(`{"type":"hello","id":1,"app":"ct","version":"0.1","platform":"test","proto":1}`))
	w := expect(t, s.pop(t), "welcome")
	if w["peer_id"] != p.ID || w["heartbeat_sec"].(float64) != 30 {
		t.Fatalf("welcome: %v", w)
	}
	ice := w["ice_servers"].([]any)
	if len(ice) != 2 {
		t.Fatalf("ice servers: %v", ice)
	}
	turn := ice[1].(map[string]any)
	if !strings.HasSuffix(turn["username"].(string), ":"+p.ID) || turn["credential"] == "" {
		t.Fatalf("turn creds: %v", turn)
	}
	return p, s
}

func (e *env) createShare(t *testing.T, p *Peer, s *fakeSink, mode string) (shareID, code string) {
	t.Helper()
	e.hub.HandleText(p, []byte(fmt.Sprintf(`{"type":"create_share","id":2,"mode":"%s","ttl_sec":600,"meta":{"files":1,"bytes":42}}`, mode)))
	m := expect(t, s.pop(t), "share_created")
	if m["id"].(float64) != 2 || m["mode"] != mode {
		t.Fatalf("share_created: %v", m)
	}
	code = m["code"].(string)
	if _, err := codes.Normalize(code); err != nil || m["code_display"] != codes.Format(code) {
		t.Fatalf("bad code %v", m)
	}
	if m["expires_at"].(float64) != float64(e.now.Add(10*time.Minute).Unix()) {
		t.Fatalf("expires_at %v", m["expires_at"])
	}
	return m["share_id"].(string), code
}

func TestHelloRequired(t *testing.T) {
	e := newEnv(t, nil)
	s := &fakeSink{}
	p := e.hub.Connect("10.0.0.1", s)
	e.hub.HandleText(p, []byte(`{"type":"create_share","id":5}`))
	m := expect(t, s.pop(t), "error")
	if m["code"] != CodeNotHello || m["id"].(float64) != 5 {
		t.Fatal(m)
	}
	e.hub.HandleText(p, []byte(`{"type":"hello","id":1,"proto":99}`))
	m = expect(t, s.pop(t), "error")
	if m["code"] != CodeUnsupported || s.kicked == "" {
		t.Fatal(m, s.kicked)
	}
	e.hub.HandleText(p, []byte(`not json`))
	expect(t, s.pop(t), "error")
}

func TestOnceFlow(t *testing.T) {
	e := newEnv(t, nil)
	sender, ss := e.connect(t, "10.0.0.1")
	receiver, rs := e.connect(t, "10.0.0.2")
	shareID, code := e.createShare(t, sender, ss, "once")

	// Claim with display form + lowercase.
	e.hub.HandleText(receiver, []byte(fmt.Sprintf(`{"type":"claim","id":3,"code":"%s"}`, strings.ToLower(codes.Format(code)))))
	rstart := expect(t, rs.pop(t), "session_start")
	sstart := expect(t, ss.pop(t), "session_start")
	if rstart["id"].(float64) != 3 || rstart["role"] != "receiver" || sstart["role"] != "sender" {
		t.Fatal(rstart, sstart)
	}
	sid := rstart["session_id"].(string)
	if sstart["session_id"] != sid || rstart["share_id"] != shareID {
		t.Fatal("session mismatch")
	}
	if rstart["remote_peer_id"] != sender.ID || sstart["remote_peer_id"] != receiver.ID {
		t.Fatal("remote peer ids")
	}
	if rstart["meta"].(map[string]any)["bytes"].(float64) != 42 {
		t.Fatal("meta not delivered to receiver")
	}
	token := rstart["resume_token"].(string)
	if token == "" || sstart["resume_token"] != token {
		t.Fatal("resume token")
	}

	// once: second claim on the same code fails with code_not_found.
	other, os := e.connect(t, "10.0.0.3")
	e.hub.HandleText(other, []byte(fmt.Sprintf(`{"type":"claim","id":4,"code":"%s"}`, code)))
	m := expect(t, os.pop(t), "error")
	if m["code"] != CodeCodeNotFound || len(e.slept) != 1 || e.slept[0] != 250*time.Millisecond {
		t.Fatal(m, e.slept)
	}

	// Signal forwarding, both directions, with and without id.
	e.hub.HandleText(receiver, []byte(fmt.Sprintf(`{"type":"signal","id":5,"session_id":"%s","payload":{"sdp":"v=0 offer"}}`, sid)))
	fwd := expect(t, ss.pop(t), "signal")
	if fwd["from"] != receiver.ID || fwd["to"] != sender.ID || fwd["payload"].(map[string]any)["sdp"] != "v=0 offer" {
		t.Fatal(fwd)
	}
	expect(t, rs.pop(t), "ok")
	e.hub.HandleText(sender, []byte(fmt.Sprintf(`{"type":"signal","session_id":"%s","to":"%s","payload":{"candidate":"c"}}`, sid, receiver.ID)))
	expect(t, rs.pop(t), "signal")
	if ss.count() != 0 {
		t.Fatal("no ok expected without id")
	}
	// Wrong `to`.
	e.hub.HandleText(sender, []byte(fmt.Sprintf(`{"type":"signal","id":6,"session_id":"%s","to":"nobody","payload":{}}`, sid)))
	if expect(t, ss.pop(t), "error")["code"] != CodeBadRequest {
		t.Fatal("wrong to accepted")
	}
	// Outsider cannot signal.
	e.hub.HandleText(other, []byte(fmt.Sprintf(`{"type":"signal","id":7,"session_id":"%s","payload":{}}`, sid)))
	if expect(t, os.pop(t), "error")["code"] != CodeSessionInvalid {
		t.Fatal("outsider signalled")
	}

	// Relay frames.
	frame, _ := relay.Encode(sid, []byte("blob"))
	e.hub.HandleBinary(sender, frame)
	if len(rs.bins) != 1 || string(rs.bins[0][relay.HeaderSize:]) != "blob" {
		t.Fatal("relay not forwarded")
	}
	e.hub.HandleBinary(other, frame)
	if expect(t, os.pop(t), "error")["code"] != CodeSessionInvalid {
		t.Fatal("outsider relayed")
	}
	if len(ss.bins) != 0 {
		t.Fatal("outsider frame forwarded")
	}
	// Frames for an unknown session are dropped without a reply.
	stale, _ := relay.Encode("0000000000000000", []byte("x"))
	e.hub.HandleBinary(other, stale)
	if os.count() != 0 {
		t.Fatal("stale relay frame answered")
	}

	// Leave from receiver: sender gets session_end, receiver gets ok.
	e.hub.HandleText(receiver, []byte(fmt.Sprintf(`{"type":"leave","id":8,"session_id":"%s"}`, sid)))
	expect(t, rs.pop(t), "ok")
	end := expect(t, ss.pop(t), "session_end")
	if end["reason"] != ReasonPeerLeft {
		t.Fatal(end)
	}
	// Token no longer resumes after an explicit leave.
	e.hub.HandleText(receiver, []byte(fmt.Sprintf(`{"type":"claim","id":9,"resume_token":"%s"}`, token)))
	if expect(t, rs.pop(t), "error")["code"] != CodeCodeNotFound {
		t.Fatal("stale token resumed")
	}

	// close_share by owner: owner gets ok only (no share_closed echo).
	e.hub.HandleText(sender, []byte(fmt.Sprintf(`{"type":"close_share","id":10,"share_id":"%s"}`, shareID)))
	expect(t, ss.pop(t), "ok")
	if ss.count() != 0 {
		t.Fatal("unexpected message after close_share", ss.pop(t))
	}
	st := e.hub.Stats()
	if st.Shares != 0 || st.Sessions != 0 || st.ClaimsOK != 1 || st.ClaimsFailed != 2 || st.RelayFrames != 1 {
		t.Fatalf("%+v", st)
	}
}

func TestResumeAfterReceiverDrop(t *testing.T) {
	e := newEnv(t, nil)
	sender, ss := e.connect(t, "10.0.0.1")
	receiver, rs := e.connect(t, "10.0.0.2")
	_, code := e.createShare(t, sender, ss, "once")
	e.hub.HandleText(receiver, []byte(fmt.Sprintf(`{"type":"claim","id":3,"code":"%s"}`, code)))
	start := expect(t, rs.pop(t), "session_start")
	expect(t, ss.pop(t), "session_start")
	sid := start["session_id"].(string)
	token := start["resume_token"].(string)

	// Receiver drops: sender is told peer_offline, session survives.
	e.hub.Disconnect(receiver)
	end := expect(t, ss.pop(t), "session_end")
	if end["reason"] != ReasonPeerOffline || end["session_id"] != sid {
		t.Fatal(end)
	}
	if e.hub.Stats().Sessions != 1 {
		t.Fatal("session should survive receiver drop")
	}
	// Signalling to the offline receiver fails with peer_offline.
	e.hub.HandleText(sender, []byte(fmt.Sprintf(`{"type":"signal","id":4,"session_id":"%s","payload":{}}`, sid)))
	if expect(t, ss.pop(t), "error")["code"] != CodePeerOffline {
		t.Fatal("expected peer_offline")
	}
	// Relay to offline receiver is silently dropped.
	frame, _ := relay.Encode(sid, []byte("x"))
	e.hub.HandleBinary(sender, frame)
	if ss.count() != 0 {
		t.Fatal("unexpected message")
	}

	// New connection resumes with token, even though the once code is gone.
	r2, r2s := e.connect(t, "10.0.0.9")
	e.hub.HandleText(r2, []byte(fmt.Sprintf(`{"type":"claim","id":5,"code":"%s"}`, code)))
	if expect(t, r2s.pop(t), "error")["code"] != CodeCodeNotFound {
		t.Fatal("consumed code should not claim")
	}
	e.hub.HandleText(r2, []byte(fmt.Sprintf(`{"type":"claim","id":6,"resume_token":"%s"}`, token)))
	rstart := expect(t, r2s.pop(t), "session_start")
	sstart := expect(t, ss.pop(t), "session_start")
	if rstart["session_id"] != sid || rstart["resumed"] != true || sstart["resumed"] != true || sstart["remote_peer_id"] != r2.ID {
		t.Fatal(rstart, sstart)
	}
	// A second resume while r2 is attached is busy.
	r3, r3s := e.connect(t, "10.0.0.10")
	e.hub.HandleText(r3, []byte(fmt.Sprintf(`{"type":"claim","id":7,"resume_token":"%s"}`, token)))
	if expect(t, r3s.pop(t), "error")["code"] != CodeShareBusy {
		t.Fatal("double resume accepted")
	}

	// Sender drops: share is closed, receiver gets session_end(peer_offline).
	e.hub.Disconnect(sender)
	end = expect(t, r2s.pop(t), "session_end")
	if end["reason"] != ReasonPeerOffline {
		t.Fatal(end)
	}
	st := e.hub.Stats()
	if st.Shares != 0 || st.Sessions != 0 || st.Peers != 2 { // r2 and r3 remain
		t.Fatalf("%+v", st)
	}
}

func TestOpenModeMultipleReceivers(t *testing.T) {
	e := newEnv(t, nil)
	sender, ss := e.connect(t, "10.0.0.1")
	shareID, code := e.createShare(t, sender, ss, "open")
	var sids []string
	var sinks []*fakeSink
	for i := 0; i < 3; i++ {
		r, rs := e.connect(t, fmt.Sprintf("10.0.1.%d", i))
		e.hub.HandleText(r, []byte(fmt.Sprintf(`{"type":"claim","id":3,"code":"%s"}`, code)))
		sids = append(sids, expect(t, rs.pop(t), "session_start")["session_id"].(string))
		sinks = append(sinks, rs)
		expect(t, ss.pop(t), "session_start")
	}
	if e.hub.Stats().Sessions != 3 || sids[0] == sids[1] {
		t.Fatal("open mode sessions")
	}
	// Owner cannot claim its own code.
	e.hub.HandleText(sender, []byte(fmt.Sprintf(`{"type":"claim","id":4,"code":"%s"}`, code)))
	if expect(t, ss.pop(t), "error")["code"] != CodeBadRequest {
		t.Fatal("self claim")
	}
	// close_share ends all sessions; each receiver gets session_end(share_closed).
	e.hub.HandleText(sender, []byte(fmt.Sprintf(`{"type":"close_share","id":5,"share_id":"%s"}`, shareID)))
	expect(t, ss.pop(t), "ok")
	if ss.count() != 0 {
		t.Fatal("owner should get only ok")
	}
	got := 0
	for _, rs := range sinks {
		if expect(t, rs.pop(t), "session_end")["reason"] == ReasonShareClosed {
			got++
		}
	}
	if got != 3 || e.hub.Stats().Sessions != 0 {
		t.Fatal("sessions not ended", got)
	}
}

func TestExpiry(t *testing.T) {
	e := newEnv(t, nil)
	sender, ss := e.connect(t, "10.0.0.1")
	_, code := e.createShare(t, sender, ss, "once")
	r, rs := e.connect(t, "10.0.0.2")
	e.now = e.now.Add(11 * time.Minute)
	e.hub.HandleText(r, []byte(fmt.Sprintf(`{"type":"claim","id":3,"code":"%s"}`, code)))
	if expect(t, rs.pop(t), "error")["code"] != CodeCodeExpired {
		t.Fatal("expected code_expired")
	}
	if n := e.hub.Sweep(); n != 1 {
		t.Fatal("sweep", n)
	}
	if expect(t, ss.pop(t), "share_closed")["reason"] != ReasonShareExpired {
		t.Fatal("share_closed reason")
	}
	// After sweep the code is gone entirely.
	e.hub.HandleText(r, []byte(fmt.Sprintf(`{"type":"claim","id":4,"code":"%s"}`, code)))
	if expect(t, rs.pop(t), "error")["code"] != CodeCodeNotFound {
		t.Fatal("expected code_not_found")
	}
}

func TestTTLClamp(t *testing.T) {
	e := newEnv(t, func(o *Options) { o.MaxOnceTTL = time.Hour; o.MaxOpenTTL = 2 * time.Hour })
	sender, ss := e.connect(t, "10.0.0.1")
	e.hub.HandleText(sender, []byte(`{"type":"create_share","id":2,"mode":"once","ttl_sec":999999}`))
	m := expect(t, ss.pop(t), "share_created")
	if m["expires_at"].(float64) != float64(e.now.Add(time.Hour).Unix()) {
		t.Fatal("once ttl not clamped")
	}
	e.hub.HandleText(sender, []byte(`{"type":"create_share","id":3,"mode":"open","ttl_sec":999999}`))
	m = expect(t, ss.pop(t), "share_created")
	if m["expires_at"].(float64) != float64(e.now.Add(2*time.Hour).Unix()) {
		t.Fatal("open ttl not clamped")
	}
	e.hub.HandleText(sender, []byte(`{"type":"create_share","id":4,"mode":"weird"}`))
	expect(t, ss.pop(t), "error")
}

func TestClaimRateLimit(t *testing.T) {
	e := newEnv(t, func(o *Options) { o.ClaimRatePerIP = 1; o.ClaimBurstPerIP = 2 })
	r, rs := e.connect(t, "10.0.0.2")
	for i := 0; i < 2; i++ {
		e.hub.HandleText(r, []byte(`{"type":"claim","id":1,"code":"3K7QW-P9X2M"}`))
		if expect(t, rs.pop(t), "error")["code"] != CodeCodeNotFound {
			t.Fatal("expected not found")
		}
	}
	e.hub.HandleText(r, []byte(`{"type":"claim","id":1,"code":"3K7QW-P9X2M"}`))
	if expect(t, rs.pop(t), "error")["code"] != CodeRateLimited {
		t.Fatal("expected rate_limited")
	}
	// Another IP is unaffected.
	r2, r2s := e.connect(t, "10.0.0.3")
	e.hub.HandleText(r2, []byte(`{"type":"claim","id":1,"code":"3K7QW-P9X2M"}`))
	if expect(t, r2s.pop(t), "error")["code"] != CodeCodeNotFound {
		t.Fatal("other ip limited")
	}
	// Refill after a second.
	e.now = e.now.Add(time.Second)
	e.hub.HandleText(r, []byte(`{"type":"claim","id":1,"code":"3K7QW-P9X2M"}`))
	if expect(t, rs.pop(t), "error")["code"] != CodeCodeNotFound {
		t.Fatal("limiter did not refill")
	}
	if len(e.slept) != 5 {
		t.Fatal("every failure must apply the constant delay", len(e.slept))
	}
	if e.hub.Stats().ClaimsLimited != 1 {
		t.Fatal("stats")
	}
}

func TestRelayRateLimit(t *testing.T) {
	e := newEnv(t, func(o *Options) { o.RelayRateLimit = 64 * 1024 })
	sender, ss := e.connect(t, "10.0.0.1")
	receiver, rs := e.connect(t, "10.0.0.2")
	_, code := e.createShare(t, sender, ss, "once")
	e.hub.HandleText(receiver, []byte(fmt.Sprintf(`{"type":"claim","id":3,"code":"%s"}`, code)))
	sid := expect(t, rs.pop(t), "session_start")["session_id"].(string)
	ss.pop(t)
	frame, _ := relay.Encode(sid, make([]byte, 16*1024-relay.HeaderSize))
	for i := 0; i < 8; i++ {
		e.hub.HandleBinary(sender, frame)
	}
	if len(rs.bins) != 4 {
		t.Fatalf("forwarded %d frames, want 4", len(rs.bins))
	}
	st := e.hub.Stats()
	if st.RelayDropped != 4 || st.RelayFrames != 4 {
		t.Fatalf("%+v", st)
	}
}

func TestPingAndShutdown(t *testing.T) {
	e := newEnv(t, nil)
	p, s := e.connect(t, "10.0.0.1")
	e.hub.HandleText(p, []byte(`{"type":"ping","id":9}`))
	m := expect(t, s.pop(t), "pong")
	if m["id"].(float64) != 9 {
		t.Fatal(m)
	}
	e.createShare(t, p, s, "open")
	e.hub.Shutdown()
	if expect(t, s.pop(t), "share_closed")["reason"] != ReasonServerClose || s.kicked != ReasonServerClose {
		t.Fatal("shutdown")
	}
}

func TestMaxShares(t *testing.T) {
	e := newEnv(t, func(o *Options) { o.MaxSharesPerPeer = 2 })
	p, s := e.connect(t, "10.0.0.1")
	e.createShare(t, p, s, "once")
	e.createShare(t, p, s, "once")
	e.hub.HandleText(p, []byte(`{"type":"create_share","id":2,"mode":"once"}`))
	if expect(t, s.pop(t), "error")["code"] != CodeTooManyShares {
		t.Fatal("limit not enforced")
	}
}
