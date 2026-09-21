package turn

import (
	"errors"
	"io"
	"log/slog"
	"net"
	"sync"
	"testing"
	"time"

	"crosstransfer/server/internal/relay"
	pionturn "github.com/pion/turn/v4"
)

type quotaTestGenerator struct{}

func (*quotaTestGenerator) Validate() error { return nil }
func (*quotaTestGenerator) AllocatePacketConn(network string, port int) (net.PacketConn, net.Addr, error) {
	if port == 1 {
		return nil, nil, errors.New("injected bind failure")
	}
	conn, err := net.ListenPacket(network, "127.0.0.1:0")
	if err != nil {
		return nil, nil, err
	}
	return conn, conn.LocalAddr(), nil
}
func (*quotaTestGenerator) AllocateConn(string, int) (net.Conn, net.Addr, error) {
	return nil, nil, errors.New("unused")
}

func TestRelayQuotaAtomicCapacityAndFailureRecovery(t *testing.T) {
	q := &relayQuota{base: &quotaTestGenerator{}, maximum: 2, global: relay.NewLimiter(0), now: time.Now}
	if _, _, err := q.AllocatePacketConn("udp4", 1); err == nil || q.Stats().Sockets != 0 {
		t.Fatal("failed bind leaked slot")
	}
	var wg sync.WaitGroup
	accepted := make(chan net.PacketConn, 32)
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if conn, _, err := q.AllocatePacketConn("udp4", 0); err == nil {
				accepted <- conn
			}
		}()
	}
	wg.Wait()
	close(accepted)
	if q.Stats().Sockets != 2 || q.Stats().Rejected != 30 {
		t.Fatal(q.Stats())
	}
	for conn := range accepted {
		conn.Close()
		conn.Close()
		if _, err := conn.WriteTo([]byte("closed"), conn.LocalAddr()); !errors.Is(err, net.ErrClosed) {
			t.Fatal("closed limited socket accepted a write", err)
		}
	}
	if q.Stats().Sockets != 0 {
		t.Fatal("close did not release exactly once", q.Stats())
	}
	conn, _, err := q.AllocatePacketConn("udp4", 0)
	if err != nil {
		t.Fatal("capacity not reusable", err)
	}
	conn.Close()
}

func TestRelayQuotaBudgetsBothDirectionsAndAllAllocations(t *testing.T) {
	for _, global := range []bool{false, true} {
		name := "per-allocation"
		if global {
			name = "aggregate"
		}
		t.Run(name, func(t *testing.T) {
			now := time.Now()
			q := &relayQuota{base: &quotaTestGenerator{}, maximum: 2, global: relay.NewLimiter(0), perAllocationRate: 64 << 10, now: func() time.Time { return now }}
			if global {
				q.global = relay.NewLimiter(64 << 10)
				q.perAllocationRate = 0
			}
			first, _, err := q.AllocatePacketConn("udp4", 0)
			if err != nil {
				t.Fatal(err)
			}
			defer first.Close()
			incoming := first
			if global {
				incoming, _, err = q.AllocatePacketConn("udp4", 0)
				if err != nil {
					t.Fatal(err)
				}
				defer incoming.Close()
			}
			peer, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer peer.Close()
			payload, buffer := make([]byte, 8192), make([]byte, 8192)
			for i := 0; i < 8; i++ {
				if _, err := first.WriteTo(payload, peer.LocalAddr()); err != nil {
					t.Fatal(err)
				}
				peer.SetReadDeadline(time.Now().Add(time.Second))
				if n, _, err := peer.ReadFrom(buffer); err != nil || n != len(payload) {
					t.Fatal(n, err)
				}
			}
			// The opposite direction shares the budget, as does another socket
			// under the aggregate policy. Exhausted reads silently drop a packet.
			peer.WriteTo(payload, incoming.LocalAddr())
			incoming.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
			if _, _, err := incoming.ReadFrom(buffer); err == nil {
				t.Fatal("over-budget packet admitted")
			}
			if q.Stats().Dropped != 1 {
				t.Fatal(q.Stats())
			}
			now = now.Add(time.Second)
			peer.WriteTo(payload, incoming.LocalAddr())
			incoming.SetReadDeadline(time.Now().Add(time.Second))
			if n, _, err := incoming.ReadFrom(buffer); err != nil || n != len(payload) {
				t.Fatal("budget did not recover", n, err)
			}
			if q.Stats().Bytes != 9*8192 {
				t.Fatal(q.Stats())
			}
		})
	}
}

func TestEmbeddedTURNQuotaRejectsAndRecovers(t *testing.T) {
	srv, err := Start(Options{PublicIP: net.ParseIP("127.0.0.1"), ListenIP: "127.0.0.1", Port: 0,
		MinPort: 41200, MaxPort: 41300, Realm: "test", Secret: "quota-secret", MaxAllocations: 1,
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil))})
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	NewClient := func(user string) *pionturn.Client {
		conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		cred := IssueCredentials("quota-secret", user, time.Minute, time.Now())
		client, err := pionturn.NewClient(&pionturn.ClientConfig{Conn: conn,
			STUNServerAddr: srv.conn.LocalAddr().String(), TURNServerAddr: srv.conn.LocalAddr().String(),
			Username: cred.Username, Password: cred.Password, Realm: "test"})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(client.Close)
		if err := client.Listen(); err != nil {
			t.Fatal(err)
		}
		return client
	}
	first, second := NewClient("first"), NewClient("second")
	allocated, err := first.Allocate()
	if err != nil {
		t.Fatal(err)
	}
	if conn, err := second.Allocate(); err == nil {
		conn.Close()
		t.Fatal("over-capacity allocation succeeded")
	}
	if srv.QuotaStats().Sockets != 1 || srv.QuotaStats().Rejected == 0 {
		t.Fatal(srv.QuotaStats())
	}
	allocated.Close()
	deadline := time.Now().Add(time.Second)
	for srv.QuotaStats().Sockets != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if srv.QuotaStats().Sockets != 0 {
		t.Fatal("Refresh(0) did not free allocation")
	}
	recovered, err := second.Allocate()
	if err != nil {
		t.Fatal("allocation after release failed", err)
	}
	defer recovered.Close()
	srv.Close()
	deadline = time.Now().Add(time.Second)
	for srv.QuotaStats().Sockets != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if srv.QuotaStats().Sockets != 0 {
		t.Fatal("server shutdown left a relay socket")
	}
}
