package turn

import (
	"bytes"
	"fmt"
	"io"
	"log/slog"
	"net"
	"testing"
	"time"

	pionturn "github.com/pion/turn/v4"
)

func TestPeerPolicyBoundaries(t *testing.T) {
	for _, value := range []string{"1.2.3.4", "8.8.8.8", "100.63.255.255", "100.128.0.0", "172.15.255.255", "172.32.0.0", "::ffff:8.8.8.8"} {
		if !PeerAllowed(net.ParseIP(value), false) {
			t.Error("public IPv4 rejected:", value)
		}
	}
	for _, value := range []string{"10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "127.0.0.1", "127.255.255.254", "100.64.0.0", "100.127.255.255", "::ffff:127.0.0.1"} {
		if PeerAllowed(net.ParseIP(value), false) || !PeerAllowed(net.ParseIP(value), true) {
			t.Error("private IPv4 override incorrect:", value)
		}
	}
	for _, value := range []string{"invalid", "0.0.0.0", "0.1.2.3", "169.254.169.254", "192.0.0.1", "192.0.2.1", "192.88.99.1", "198.18.0.1", "198.19.255.255", "198.51.100.1", "203.0.113.1", "224.0.0.1", "239.255.255.255", "240.0.0.1", "255.255.255.255", "::1", "fe80::1", "fc00::1", "2001:4860:4860::8888", "::ffff:169.254.169.254"} {
		for _, allowPrivate := range []bool{false, true} {
			if PeerAllowed(net.ParseIP(value), allowPrivate) {
				t.Errorf("unsafe/unsupported peer %s accepted (private=%v)", value, allowPrivate)
			}
		}
	}
}

func TestEmbeddedTURNEnforcesPeerPolicy(t *testing.T) {
	for _, allowPrivate := range []bool{false, true} {
		t.Run(fmt.Sprintf("allowPrivate=%v", allowPrivate), func(t *testing.T) {
			srv, err := Start(Options{
				PublicIP: net.ParseIP("127.0.0.1"), ListenIP: "127.0.0.1",
				Port: 0, MinPort: 41000, MaxPort: 41100, Realm: "test", Secret: "test-secret",
				AllowPrivatePeers: allowPrivate, Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
			})
			if err != nil {
				t.Fatal(err)
			}
			defer srv.Close()
			pc, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer pc.Close()
			cred := IssueCredentials("test-secret", "peer", time.Minute, time.Now())
			client, err := pionturn.NewClient(&pionturn.ClientConfig{
				STUNServerAddr: srv.conn.LocalAddr().String(), TURNServerAddr: srv.conn.LocalAddr().String(),
				Conn: pc, Username: cred.Username, Password: cred.Password, Realm: "test",
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
			peer, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer peer.Close()
			// CreatePermission only installs server state; no packets go to these
			// remote IPs. All actual payload traffic below stays on loopback.
			public := &net.UDPAddr{IP: net.ParseIP("8.8.8.8"), Port: 12345}
			metadata := &net.UDPAddr{IP: net.ParseIP("169.254.169.254"), Port: 80}
			if err := client.CreatePermission(public); err != nil {
				t.Fatal("public permission rejected:", err)
			}
			if err := client.CreatePermission(metadata); err == nil {
				t.Fatal("metadata service permission accepted")
			}
			err = client.CreatePermission(peer.LocalAddr())
			if (err == nil) != allowPrivate {
				t.Fatalf("loopback permission error = %v", err)
			}
			payload := []byte("isolated TURN policy check")
			_, err = relay.WriteTo(payload, peer.LocalAddr())
			if (err == nil) != allowPrivate {
				t.Fatalf("loopback relay error = %v", err)
			}
			buffer := make([]byte, 128)
			if allowPrivate {
				peer.SetReadDeadline(time.Now().Add(2 * time.Second))
				n, from, err := peer.ReadFrom(buffer)
				if err != nil || !bytes.Equal(buffer[:n], payload) {
					t.Fatal("allowed relay failed:", n, err)
				}
				if _, err = peer.WriteTo(payload, from); err != nil {
					t.Fatal(err)
				}
				relay.SetReadDeadline(time.Now().Add(2 * time.Second))
				n, _, err = relay.ReadFrom(buffer)
				if err != nil || !bytes.Equal(buffer[:n], payload) {
					t.Fatal("allowed return relay failed:", n, err)
				}
			} else {
				peer.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
				if _, _, err = peer.ReadFrom(buffer); err == nil {
					t.Fatal("denied peer received a payload")
				}
			}
		})
	}
}
