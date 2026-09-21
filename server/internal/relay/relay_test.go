package relay

import (
	"bytes"
	"testing"
	"time"
)

func TestEncodeParse(t *testing.T) {
	sid := "0123456789abcdef"
	payload := []byte("hello")
	f, err := Encode(sid, payload)
	if err != nil {
		t.Fatal(err)
	}
	if len(f) != HeaderSize+len(payload) {
		t.Fatal(len(f))
	}
	got, err := ParseHeader(f)
	if err != nil || got != sid {
		t.Fatal(got, err)
	}
	if !bytes.Equal(f[HeaderSize:], payload) {
		t.Fatal("payload mismatch")
	}
	if _, err := Encode("short", nil); err == nil {
		t.Fatal("short session id accepted")
	}
	if _, err := ParseHeader(f[:10]); err != ErrShortFrame {
		t.Fatal(err)
	}
	bad := append([]byte{}, f...)
	bad[0] = 'X'
	if _, err := ParseHeader(bad); err != ErrBadMagic {
		t.Fatal(err)
	}
	bad = append([]byte{}, f...)
	bad[2] = 9
	if _, err := ParseHeader(bad); err != ErrBadVersion {
		t.Fatal(err)
	}
}

func TestLimiter(t *testing.T) {
	now := time.Now()
	unlimited := NewLimiter(0)
	for i := 0; i < 1000; i++ {
		if !unlimited.Allow(1<<20, now) {
			t.Fatal("unlimited limiter refused")
		}
	}
	l := NewLimiter(100 * 1024) // 100 KiB/s, burst 100 KiB
	allowed := 0
	for i := 0; i < 20; i++ {
		if l.Allow(10*1024, now) {
			allowed++
		}
	}
	if allowed != 10 {
		t.Fatalf("allowed %d frames, want 10", allowed)
	}
	frames, b, dropped := l.Stats()
	if frames != 10 || b != 100*1024 || dropped != 10 {
		t.Fatal(frames, b, dropped)
	}
	if !l.Allow(10*1024, now.Add(200*time.Millisecond)) {
		t.Fatal("refill did not happen")
	}
}
