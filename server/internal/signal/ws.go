package signal

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

// WSOptions configures the WebSocket endpoint.
type WSOptions struct {
	MaxConnections      int
	MaxConnectionsPerIP int
	MaxMessageSize      int64
	HeartbeatSec        int
	// TrustProxy enables X-Forwarded-For / X-Real-IP for client IP detection.
	TrustProxy bool
	Logger     *slog.Logger
}

// wsSink is a Sink backed by a coder/websocket connection with an outbound
// queue drained by a dedicated writer goroutine.
type wsSink struct {
	conn         *websocket.Conn
	out          chan outMsg
	closed       chan struct{}
	once         sync.Once
	reason       string
	dropped      atomic.Uint64
	queuedBytes  atomic.Int64
	queueDropped *atomic.Uint64
}

type outMsg struct {
	typ  websocket.MessageType
	data []byte
}

const outQueue = 512
const MaxQueuedBytes = 4 << 20

func (s *wsSink) enqueue(m outMsg) {
	if s.queuedBytes.Add(int64(len(m.data))) > MaxQueuedBytes {
		s.queuedBytes.Add(-int64(len(m.data)))
		if m.typ == websocket.MessageBinary {
			s.RecordDrop()
		} else {
			s.Kick("send queue byte limit")
		}
		return
	}
	select {
	case <-s.closed:
		s.queuedBytes.Add(-int64(len(m.data)))
	case s.out <- m:
	default:
		s.queuedBytes.Add(-int64(len(m.data)))
		if m.typ == websocket.MessageBinary {
			// Relay frames are unreliable by contract: drop under pressure so
			// the peers' congestion control sees loss instead of a dead link.
			s.RecordDrop()
			return
		}
		// A control message could not be queued: the client is not reading.
		s.Kick("send queue overflow")
	}
}

// Dropped returns the number of relay frames discarded by this sink.
func (s *wsSink) Dropped() uint64 { return s.dropped.Load() }

func (s *wsSink) RecordDrop() {
	s.dropped.Add(1)
	if s.queueDropped != nil {
		s.queueDropped.Add(1)
	}
}

func (s *wsSink) SendText(msg []byte)     { s.enqueue(outMsg{websocket.MessageText, msg}) }
func (s *wsSink) SendBinary(frame []byte) { s.enqueue(outMsg{websocket.MessageBinary, frame}) }
func (s *wsSink) Kick(reason string) {
	s.once.Do(func() {
		s.reason = reason
		close(s.closed)
	})
}

// ServeWS returns the HTTP handler for /ws.
func ServeWS(h *Hub, o WSOptions) http.Handler {
	if o.MaxConnections <= 0 {
		o.MaxConnections = 1024
	}
	if o.MaxConnectionsPerIP <= 0 {
		o.MaxConnectionsPerIP = 32
	}
	var slots sync.Mutex
	active := 0
	perIP := make(map[string]int)
	log := o.Logger
	if log == nil {
		log = slog.Default()
	}
	heartbeat := time.Duration(o.HeartbeatSec) * time.Second
	if heartbeat <= 0 {
		heartbeat = 30 * time.Second
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r, o.TrustProxy)
		slots.Lock()
		if active >= o.MaxConnections || perIP[ip] >= o.MaxConnectionsPerIP {
			slots.Unlock()
			h.mu.Lock()
			h.stats.ConnectionsLimited++
			h.mu.Unlock()
			w.Header().Set("Retry-After", "5")
			http.Error(w, "signaling capacity reached", http.StatusServiceUnavailable)
			return
		}
		active++
		perIP[ip]++
		slots.Unlock()
		defer func() {
			slots.Lock()
			active--
			perIP[ip]--
			if perIP[ip] == 0 {
				delete(perIP, ip)
			}
			slots.Unlock()
		}()
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
			Subprotocols:       []string{"ct-signal-v1"},
			InsecureSkipVerify: true, // native clients; no browser origin policy
			CompressionMode:    websocket.CompressionDisabled,
		})
		if err != nil {
			log.Debug("ws accept failed", "err", err)
			return
		}
		if o.MaxMessageSize > 0 {
			conn.SetReadLimit(o.MaxMessageSize)
		}
		sink := &wsSink{conn: conn, out: make(chan outMsg, outQueue), closed: make(chan struct{}), queueDropped: &h.queueDropped}
		peer := h.Connect(ip, sink)
		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()

		// Writer goroutine.
		writerDone := make(chan struct{})
		go func() {
			defer close(writerDone)
			for {
				select {
				case <-sink.closed:
					return
				case <-ctx.Done():
					return
				case m := <-sink.out:
					sink.queuedBytes.Add(-int64(len(m.data)))
					wctx, wcancel := context.WithTimeout(ctx, 10*time.Second)
					err := conn.Write(wctx, m.typ, m.data)
					wcancel()
					if err != nil {
						sink.Kick("write failed")
						return
					}
				}
			}
		}()

		// Keep-alive: server-side ping at the heartbeat interval; the read
		// deadline is 2× heartbeat so a dead client is reaped.
		go func() {
			t := time.NewTicker(heartbeat)
			defer t.Stop()
			for {
				select {
				case <-sink.closed:
					return
				case <-ctx.Done():
					return
				case <-t.C:
					pctx, pcancel := context.WithTimeout(ctx, heartbeat)
					err := conn.Ping(pctx)
					pcancel()
					if err != nil {
						sink.Kick("ping timeout")
						return
					}
				}
			}
		}()

		// Reader loop (this goroutine).
		go func() {
			<-sink.closed
			cancel()
		}()
		for {
			typ, data, err := conn.Read(ctx)
			if err != nil {
				break
			}
			switch typ {
			case websocket.MessageText:
				h.HandleText(peer, data)
			case websocket.MessageBinary:
				h.HandleBinary(peer, data)
			}
		}
		h.Disconnect(peer)
		sink.Kick("read closed")
		<-writerDone
		reason := sink.reason
		code := websocket.StatusNormalClosure
		if reason != "read closed" {
			code = websocket.StatusPolicyViolation
			log.Info("connection dropped", "peer", peer.ID, "reason", reason, "relay_dropped", sink.Dropped())
		} else if d := sink.Dropped(); d > 0 {
			log.Debug("connection closed", "peer", peer.ID, "relay_dropped", d)
		}
		_ = conn.Close(code, reason)
	})
}

func clientIP(r *http.Request, trustProxy bool) string {
	if trustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			if first, _, ok := strings.Cut(xff, ","); ok {
				return strings.TrimSpace(first)
			}
			return strings.TrimSpace(xff)
		}
		if rip := r.Header.Get("X-Real-IP"); rip != "" {
			return rip
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// IsNormalClose reports whether err is an expected close.
func IsNormalClose(err error) bool {
	var ce websocket.CloseError
	if errors.As(err, &ce) {
		return ce.Code == websocket.StatusNormalClosure || ce.Code == websocket.StatusGoingAway
	}
	return errors.Is(err, context.Canceled)
}
