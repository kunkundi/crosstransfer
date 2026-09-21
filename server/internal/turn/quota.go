package turn

import (
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"crosstransfer/server/internal/relay"
	pionturn "github.com/pion/turn/v4"
)

// QuotaStats describes actual embedded relay sockets and admitted UDP payload.
// A datagram crossing two relay sockets counts at each socket, in each direction.
type QuotaStats struct {
	Sockets  int
	Rejected uint64
	Bytes    uint64
	Dropped  uint64
}

// relayQuota serializes the allocation check with socket creation. A callback
// that merely reads AllocationCount before creation can overshoot under load.
type relayQuota struct {
	base              pionturn.RelayAddressGenerator
	mu                sync.Mutex
	active            int
	maximum           int
	perAllocationRate int
	global            *relay.Limiter
	now               func() time.Time
	rejected          atomic.Uint64
	bytes             atomic.Uint64
	dropped           atomic.Uint64
}

func (q *relayQuota) Validate() error { return q.base.Validate() }

func (q *relayQuota) AllocatePacketConn(network string, requestedPort int) (net.PacketConn, net.Addr, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.active >= q.maximum {
		q.rejected.Add(1)
		return nil, nil, errors.New("TURN relay socket capacity reached")
	}
	conn, address, err := q.base.AllocatePacketConn(network, requestedPort)
	if err != nil {
		return nil, nil, err
	}
	q.active++
	return &quotaPacketConn{PacketConn: conn, quota: q, limiter: relay.NewLimiter(q.perAllocationRate)}, address, nil
}

func (q *relayQuota) AllocateConn(string, int) (net.Conn, net.Addr, error) {
	return nil, nil, errors.New("embedded TURN supports UDP only")
}

func (q *relayQuota) Stats() QuotaStats {
	q.mu.Lock()
	active := q.active
	q.mu.Unlock()
	return QuotaStats{Sockets: active, Rejected: q.rejected.Load(), Bytes: q.bytes.Load(), Dropped: q.dropped.Load()}
}

type quotaPacketConn struct {
	net.PacketConn
	quota      *relayQuota
	limiter    *relay.Limiter
	closed     sync.Once
	isClosed   atomic.Bool
	closeError error
}

func (c *quotaPacketConn) Allow(n int) bool {
	now := c.quota.now()
	if !c.limiter.Allow(n, now) || !c.quota.global.Allow(n, now) {
		c.quota.dropped.Add(1)
		return false
	}
	c.quota.bytes.Add(uint64(n))
	return true
}

func (c *quotaPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	for {
		n, address, err := c.PacketConn.ReadFrom(p)
		if err != nil || c.Allow(n) {
			return n, address, err
		}
		// UDP drops are recovered by the client's existing SACK/KCP protocol.
	}
}

func (c *quotaPacketConn) WriteTo(p []byte, address net.Addr) (int, error) {
	if c.isClosed.Load() {
		return 0, net.ErrClosed
	}
	if !c.Allow(len(p)) {
		return len(p), nil
	}
	return c.PacketConn.WriteTo(p, address)
}

func (c *quotaPacketConn) Close() error {
	c.closed.Do(func() {
		c.isClosed.Store(true)
		c.closeError = c.PacketConn.Close()
		c.quota.mu.Lock()
		c.quota.active--
		c.quota.mu.Unlock()
	})
	return c.closeError
}
