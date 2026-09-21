// Package relay defines the binary WebSocket relay frame used when ICE fails
// and both peers fall back to forwarding through the signaling server.
//
// Frame layout (binary WebSocket message):
//
//	magic     2 bytes  "CR"
//	version   1 byte   0x01
//	flags     1 byte   reserved (0)
//	sessionId 16 bytes ASCII session ID (as issued in session_start)
//	payload   N bytes  opaque; the server never inspects it
//
// The server only validates the header, checks that the sender belongs to the
// session, applies the per-connection rate limit and forwards the frame
// unchanged to the other party.
package relay

import (
	"errors"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

const (
	HeaderSize   = 2 + 1 + 1 + 16
	SessionIDLen = 16
	Version      = 0x01
)

var (
	ErrShortFrame  = errors.New("relay: frame too short")
	ErrBadMagic    = errors.New("relay: bad magic")
	ErrBadVersion  = errors.New("relay: unsupported version")
	ErrRateLimited = errors.New("relay: rate limited")
)

var magic = [2]byte{'C', 'R'}

// Encode builds a relay frame for sessionID carrying payload.
func Encode(sessionID string, payload []byte) ([]byte, error) {
	if len(sessionID) != SessionIDLen {
		return nil, errors.New("relay: session id must be 16 bytes")
	}
	out := make([]byte, HeaderSize+len(payload))
	out[0], out[1] = magic[0], magic[1]
	out[2] = Version
	out[3] = 0
	copy(out[4:4+SessionIDLen], sessionID)
	copy(out[HeaderSize:], payload)
	return out, nil
}

// ParseHeader validates the header of frame and returns the session ID. The
// payload is frame[HeaderSize:]; it is not copied.
func ParseHeader(frame []byte) (sessionID string, err error) {
	if len(frame) < HeaderSize {
		return "", ErrShortFrame
	}
	if frame[0] != magic[0] || frame[1] != magic[1] {
		return "", ErrBadMagic
	}
	if frame[2] != Version {
		return "", ErrBadVersion
	}
	return string(frame[4 : 4+SessionIDLen]), nil
}

// Limiter is a per-connection byte-rate policer. A zero limit disables it.
type Limiter struct {
	mu      sync.Mutex
	limiter *rate.Limiter
	dropped uint64
	bytes   uint64
	frames  uint64
}

// NewLimiter creates a policer permitting bytesPerSec with a burst of one
// second's worth of traffic (minimum 64 KiB so a single frame always fits).
func NewLimiter(bytesPerSec int) *Limiter {
	l := &Limiter{}
	if bytesPerSec > 0 {
		burst := bytesPerSec
		if burst < 64*1024 {
			burst = 64 * 1024
		}
		l.limiter = rate.NewLimiter(rate.Limit(bytesPerSec), burst)
	}
	return l
}

// Allow reports whether a frame of n bytes may be forwarded now.
func (l *Limiter) Allow(n int, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.limiter != nil && !l.limiter.AllowN(now, n) {
		l.dropped++
		return false
	}
	l.frames++
	l.bytes += uint64(n)
	return true
}

// Stats returns forwarded frames, forwarded bytes and dropped frames.
func (l *Limiter) Stats() (frames, bytes, dropped uint64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.frames, l.bytes, l.dropped
}
