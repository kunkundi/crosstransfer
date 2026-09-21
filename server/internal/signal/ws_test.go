package signal

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"crosstransfer/server/internal/relay"
	"github.com/coder/websocket"
)

type inbound struct {
	typ  websocket.MessageType
	data []byte
}

// wsClient mimics a native client: a dedicated reader goroutine so control
// frames (server keep-alive pings) are answered even while the test is idle.
type wsClient struct {
	t    *testing.T
	conn *websocket.Conn
	ctx  context.Context
	in   chan inbound
	err  chan error
}

func dial(t *testing.T, srv *httptest.Server) *wsClient {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	conn, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{Subprotocols: []string{"ct-signal-v1"}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close(websocket.StatusNormalClosure, "") })
	c := &wsClient{t: t, conn: conn, ctx: ctx, in: make(chan inbound, 64), err: make(chan error, 1)}
	go func() {
		for {
			mt, data, err := conn.Read(ctx)
			if err != nil {
				c.err <- err
				return
			}
			c.in <- inbound{mt, data}
		}
	}()
	return c
}

func (c *wsClient) send(s string) {
	if err := c.conn.Write(c.ctx, websocket.MessageText, []byte(s)); err != nil {
		c.t.Fatal(err)
	}
}

func (c *wsClient) next() (inbound, error) {
	select {
	case m := <-c.in:
		return m, nil
	case err := <-c.err:
		return inbound{}, err
	case <-c.ctx.Done():
		return inbound{}, c.ctx.Err()
	}
}

func (c *wsClient) recv(typ string) map[string]any {
	c.t.Helper()
	for {
		m, err := c.next()
		if err != nil {
			c.t.Fatalf("read: %v", err)
		}
		if m.typ != websocket.MessageText {
			continue
		}
		var v map[string]any
		if err := json.Unmarshal(m.data, &v); err != nil {
			c.t.Fatal(err)
		}
		if v["type"] != typ {
			c.t.Fatalf("want %s, got %v", typ, v)
		}
		return v
	}
}

func (c *wsClient) recvBinary() []byte {
	c.t.Helper()
	m, err := c.next()
	if err != nil || m.typ != websocket.MessageBinary {
		c.t.Fatalf("binary read: %v %v", m.typ, err)
	}
	return m.data
}

func TestWebSocketEndToEnd(t *testing.T) {
	hub := NewHub(Options{
		STUNURIs:        []string{"stun:127.0.0.1:3478"},
		HeartbeatSec:    1,
		ClaimRatePerIP:  100,
		ClaimBurstPerIP: 100,
		ClaimFailDelay:  time.Millisecond,
	})
	mux := http.NewServeMux()
	mux.Handle("/ws", ServeWS(hub, WSOptions{MaxMessageSize: 1 << 20, HeartbeatSec: 1}))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	sender := dial(t, srv)
	receiver := dial(t, srv)
	sender.send(`{"type":"hello","id":1,"app":"ct","version":"0","platform":"test","proto":1}`)
	receiver.send(`{"type":"hello","id":1,"app":"ct","version":"0","platform":"test","proto":1}`)
	sw := sender.recv("welcome")
	receiver.recv("welcome")
	if sw["peer_id"] == "" {
		t.Fatal("no peer id")
	}

	sender.send(`{"type":"create_share","id":2,"mode":"once","ttl_sec":60}`)
	created := sender.recv("share_created")
	code := created["code"].(string)

	receiver.send(fmt.Sprintf(`{"type":"claim","id":3,"code":"%s"}`, code))
	rstart := receiver.recv("session_start")
	sstart := sender.recv("session_start")
	sid := rstart["session_id"].(string)
	if sstart["session_id"] != sid {
		t.Fatal("session mismatch")
	}

	receiver.send(fmt.Sprintf(`{"type":"signal","id":4,"session_id":"%s","payload":{"sdp":"offer"}}`, sid))
	fwd := sender.recv("signal")
	if fwd["payload"].(map[string]any)["sdp"] != "offer" {
		t.Fatal(fwd)
	}
	receiver.recv("ok")
	sender.send(fmt.Sprintf(`{"type":"signal","session_id":"%s","payload":{"sdp":"answer"}}`, sid))
	receiver.recv("signal")

	// Relay: binary frame both ways.
	frame, _ := relay.Encode(sid, []byte("payload-from-sender"))
	if err := sender.conn.Write(sender.ctx, websocket.MessageBinary, frame); err != nil {
		t.Fatal(err)
	}
	got := receiver.recvBinary()
	if string(got[relay.HeaderSize:]) != "payload-from-sender" {
		t.Fatal(string(got))
	}
	frame, _ = relay.Encode(sid, []byte("payload-from-receiver"))
	receiver.conn.Write(receiver.ctx, websocket.MessageBinary, frame)
	if string(sender.recvBinary()[relay.HeaderSize:]) != "payload-from-receiver" {
		t.Fatal("reverse relay")
	}

	// Ping/pong and server keep-alive pings survive a couple of heartbeats.
	sender.send(`{"type":"ping","id":5}`)
	sender.recv("pong")
	time.Sleep(2200 * time.Millisecond)
	sender.send(`{"type":"ping","id":6}`)
	sender.recv("pong")

	// Leave.
	receiver.send(fmt.Sprintf(`{"type":"leave","id":7,"session_id":"%s"}`, sid))
	receiver.recv("ok")
	end := sender.recv("session_end")
	if end["reason"] != ReasonPeerLeft {
		t.Fatal(end)
	}

	// Disconnect of the sender closes the share; hub state is clean.
	sender.conn.Close(websocket.StatusNormalClosure, "bye")
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		st := hub.Stats()
		if st.Shares == 0 && st.Peers == 1 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("hub not cleaned: %+v", hub.Stats())
}

func TestWebSocketRejectsOversize(t *testing.T) {
	hub := NewHub(Options{ClaimFailDelay: time.Millisecond})
	mux := http.NewServeMux()
	mux.Handle("/ws", ServeWS(hub, WSOptions{MaxMessageSize: 4096, HeartbeatSec: 30}))
	srv := httptest.NewServer(mux)
	defer srv.Close()
	c := dial(t, srv)
	c.send(`{"type":"hello","id":1,"proto":1}`)
	c.recv("welcome")
	c.send(`{"type":"create_share","id":2,"meta":"` + strings.Repeat("x", 8192) + `"}`)
	if _, err := c.next(); err == nil {
		t.Fatal("expected connection close on oversize message")
	}
}

func TestWebSocketConnectionCapacityAndRelease(t *testing.T) {
	hub := NewHub(Options{})
	srv := httptest.NewServer(ServeWS(hub, WSOptions{MaxConnections: 2, MaxConnectionsPerIP: 1, TrustProxy: true}))
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	connect := func(ip string) (*websocket.Conn, int) {
		conn, response, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: http.Header{"X-Forwarded-For": []string{ip}}})
		if err != nil {
			if response == nil {
				t.Fatal(err)
			}
			if response.Header.Get("Retry-After") != "5" {
				t.Fatal("missing retry hint")
			}
			return nil, response.StatusCode
		}
		t.Cleanup(func() { conn.CloseNow() })
		return conn, http.StatusSwitchingProtocols
	}
	first, status := connect("192.0.2.1")
	if status != 101 {
		t.Fatal(status)
	}
	if _, status = connect("192.0.2.1"); status != 503 {
		t.Fatal("per-IP cap", status)
	}
	if _, status = connect("192.0.2.2"); status != 101 {
		t.Fatal(status)
	}
	if _, status = connect("192.0.2.3"); status != 503 {
		t.Fatal("global cap", status)
	}
	first.CloseNow()
	for {
		if _, status = connect("192.0.2.1"); status == 101 {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("closed connection did not free slot")
		default:
			time.Sleep(time.Millisecond)
		}
	}
	if hub.Stats().ConnectionsLimited < 2 {
		t.Fatal(hub.Stats())
	}
}

func TestWebSocketFailedUpgradeReleasesCapacity(t *testing.T) {
	hub := NewHub(Options{})
	handler := ServeWS(hub, WSOptions{MaxConnections: 1, MaxConnectionsPerIP: 1})
	for i := 0; i < 3; i++ {
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "http://example.com/ws", nil))
		if w.Code == 503 {
			t.Fatal("failed HTTP upgrade leaked a slot")
		}
	}
}

func TestWebSocketQueueByteBudget(t *testing.T) {
	sink := &wsSink{out: make(chan outMsg, outQueue), closed: make(chan struct{})}
	data := make([]byte, 1<<20)
	for i := 0; i < 8; i++ {
		sink.SendBinary(data)
	}
	if len(sink.out) != 4 || sink.Dropped() != 4 || sink.queuedBytes.Load() != MaxQueuedBytes {
		t.Fatal("byte budget exceeded")
	}
	m := <-sink.out
	sink.queuedBytes.Add(-int64(len(m.data)))
	sink.SendBinary(data)
	if len(sink.out) != 4 || sink.queuedBytes.Load() != MaxQueuedBytes {
		t.Fatal("drained byte budget not reusable")
	}
	sink.SendText([]byte("control"))
	select {
	case <-sink.closed:
	default:
		t.Fatal("overflowed reliable control must close peer")
	}
}
