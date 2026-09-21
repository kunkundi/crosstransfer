package config

import (
	"testing"
	"time"
)

func TestApplyEnvAndValidate(t *testing.T) {
	env := map[string]string{
		"CT_LISTEN":            ":9000",
		"CT_PUBLIC_IP":         "203.0.113.5",
		"CT_TURN_PORT":         "3478",
		"CT_TURN_PORT_RANGE":   "50000-50100",
		"CT_TURN_SECRET":       "s3cret",
		"CT_RELAY_RATE_LIMIT":  "1048576",
		"CT_CLAIM_RATE_PER_IP": "0.5",
		"CT_TURN_CRED_TTL":     "5m",
		"CT_METRICS":           "true",
		"CT_STUN_SERVERS":      "stun.example.org:3478, 198.51.100.2:3478",
	}
	cfg := Default()
	if err := cfg.applyEnv(func(k string) (string, bool) { v, ok := env[k]; return v, ok }); err != nil {
		t.Fatal(err)
	}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	if cfg.Listen != ":9000" || cfg.RelayRateLimit != 1048576 || cfg.ClaimRatePerIP != 0.5 || cfg.TURNCredTTL != 5*time.Minute || !cfg.Metrics {
		t.Fatalf("%+v", cfg)
	}
	lo, hi, err := cfg.TURNPorts()
	if err != nil || lo != 50000 || hi != 50100 {
		t.Fatal(lo, hi, err)
	}
	if got := cfg.TURNURI(); got != "turn:203.0.113.5:3478?transport=udp" {
		t.Fatal(got)
	}
	stun := cfg.STUNURIs()
	if len(stun) != 2 || stun[0] != "stun:stun.example.org:3478" || stun[1] != "stun:198.51.100.2:3478" {
		t.Fatal(stun)
	}
}

func TestValidateErrors(t *testing.T) {
	c := Default()
	if err := c.Validate(); err == nil {
		t.Fatal("embedded TURN without public_ip must fail")
	}
	c.TURNPort = 0
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	c.TLSCert = "a"
	if err := c.Validate(); err == nil {
		t.Fatal("cert without key must fail")
	}
	c.TLSKey = "b"
	c.ACMEDomain = "x"
	if err := c.Validate(); err == nil {
		t.Fatal("cert + acme must fail")
	}
	c = Default()
	c.PublicIP = "1.2.3.4"
	c.TURNPortRange = "70000-1"
	if err := c.Validate(); err == nil {
		t.Fatal("bad range must fail")
	}
	c.TURNPortRange = "49152-65535"
	c.ExternalTURN = "turn:coturn.example.org:3478"
	if c.EmbeddedTURNEnabled() {
		t.Fatal("external turn must disable embedded")
	}
	if c.TURNURI() != "turn:coturn.example.org:3478" {
		t.Fatal(c.TURNURI())
	}
}

func TestApplyEnvBadValue(t *testing.T) {
	c := Default()
	err := c.applyEnv(func(k string) (string, bool) {
		if k == "CT_TURN_PORT" {
			return "abc", true
		}
		return "", false
	})
	if err == nil {
		t.Fatal("expected parse error")
	}
}
