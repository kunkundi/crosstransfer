package turn

import (
	"net"
	"testing"
	"time"

	pionturn "github.com/pion/turn/v4"
)

func TestCredentialsRoundTrip(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	c := IssueCredentials("secret", "peer123", 10*time.Minute, now)
	if c.Username != "1800000600:peer123" {
		t.Fatal(c.Username)
	}
	if !VerifyCredentials("secret", c.Username, c.Password, now) {
		t.Fatal("verify failed")
	}
	if VerifyCredentials("secret", c.Username, c.Password, now.Add(11*time.Minute)) {
		t.Fatal("expired credentials accepted")
	}
	if VerifyCredentials("other", c.Username, c.Password, now) {
		t.Fatal("wrong secret accepted")
	}
	if VerifyCredentials("secret", "garbage", c.Password, now) {
		t.Fatal("malformed username accepted")
	}
	// Must match pion's own REST credential generator (same algorithm as coturn).
	u, p, err := pionturn.GenerateLongTermTURNRESTCredentials("secret", "peer123", 10*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if !VerifyCredentials("secret", u, p, time.Now()) {
		t.Fatal("pion-generated credentials rejected")
	}
}

func TestEmbeddedServerAllocates(t *testing.T) {
	srv, err := Start(Options{
		PublicIP: net.ParseIP("127.0.0.1"),
		Port:     0,
		MinPort:  40000,
		MaxPort:  40100,
		Realm:    "test",
		Secret:   "secret",
	})
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	if !srv.conn.LocalAddr().(*net.UDPAddr).IP.IsLoopback() {
		t.Fatal("a loopback-advertised TURN server must bind loopback")
	}

	cred := IssueCredentials("secret", "u", time.Minute, time.Now())
	pc, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	client, err := pionturn.NewClient(&pionturn.ClientConfig{
		STUNServerAddr: srv.conn.LocalAddr().String(),
		TURNServerAddr: srv.conn.LocalAddr().String(),
		Conn:           pc,
		Username:       cred.Username,
		Password:       cred.Password,
		Realm:          "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if err := client.Listen(); err != nil {
		t.Fatal(err)
	}
	relay, err := client.Allocate()
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Close()
	addr := relay.LocalAddr().(*net.UDPAddr)
	if addr.Port < 40000 || addr.Port > 40100 {
		t.Fatalf("relay port %d outside range", addr.Port)
	}
	if srv.AllocationCount() != 1 {
		t.Fatalf("allocations = %d", srv.AllocationCount())
	}

	// Bad credentials are rejected.
	pc2, _ := net.ListenPacket("udp4", "127.0.0.1:0")
	defer pc2.Close()
	bad, err := pionturn.NewClient(&pionturn.ClientConfig{
		STUNServerAddr: srv.conn.LocalAddr().String(),
		TURNServerAddr: srv.conn.LocalAddr().String(),
		Conn:           pc2,
		Username:       cred.Username,
		Password:       "wrong",
		Realm:          "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	defer bad.Close()
	bad.Listen()
	if _, err := bad.Allocate(); err == nil {
		t.Fatal("allocation with wrong password succeeded")
	}
}
