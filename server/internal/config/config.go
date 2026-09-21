// Package config loads server configuration from environment variables with
// an optional YAML file as the base layer. Environment variables always win.
package config

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Config is the complete server configuration.
type Config struct {
	DownloadURL    string `yaml:"download_url"`    // CT_DOWNLOAD_URL, HTTPS release/download page
	AssociationDir string `yaml:"association_dir"` // CT_ASSOCIATION_DIR, generated platform association JSON

	Listen        string        `yaml:"listen"`          // CT_LISTEN, e.g. ":8443"
	TLSCert       string        `yaml:"tls_cert"`        // CT_TLS_CERT
	TLSKey        string        `yaml:"tls_key"`         // CT_TLS_KEY
	ACMEDomain    string        `yaml:"acme_domain"`     // CT_ACME_DOMAIN
	ACMECacheDir  string        `yaml:"acme_cache_dir"`  // CT_ACME_CACHE_DIR
	PublicIP      string        `yaml:"public_ip"`       // CT_PUBLIC_IP (relay/STUN address advertised to clients)
	STUNServers   []string      `yaml:"stun_servers"`    // CT_STUN_SERVERS (comma separated; default = public_ip:turn_port)
	TURNPort      int           `yaml:"turn_port"`       // CT_TURN_PORT (0 disables the embedded TURN)
	TURNPortRange string        `yaml:"turn_port_range"` // CT_TURN_PORT_RANGE "49152-65535"
	TURNSecret    string        `yaml:"turn_secret"`     // CT_TURN_SECRET (HMAC shared secret; generated if empty)
	TURNRealm     string        `yaml:"turn_realm"`      // CT_TURN_REALM
	ExternalTURN  string        `yaml:"external_turn"`   // CT_EXTERNAL_TURN "turn:host:port" (disables embedded TURN)
	TURNCredTTL   time.Duration `yaml:"turn_cred_ttl"`   // CT_TURN_CRED_TTL

	RelayRateLimit   int           `yaml:"relay_rate_limit"`  // CT_RELAY_RATE_LIMIT bytes/sec per connection (0 = unlimited)
	ClaimRatePerIP   float64       `yaml:"claim_rate_per_ip"` // CT_CLAIM_RATE_PER_IP claims/sec
	ClaimBurstPerIP  int           `yaml:"claim_burst_per_ip"`
	ClaimRateGlobal  float64       `yaml:"claim_rate_global"`
	ClaimBurstGlobal int           `yaml:"claim_burst_global"`
	ClaimFailDelay   time.Duration `yaml:"claim_fail_delay"` // constant delay on failed claim

	HeartbeatSec    int           `yaml:"heartbeat_sec"` // CT_HEARTBEAT_SEC
	DefaultShareTTL time.Duration `yaml:"default_share_ttl"`
	MaxOnceTTL      time.Duration `yaml:"max_once_ttl"`
	MaxOpenTTL      time.Duration `yaml:"max_open_ttl"`
	MaxMessageSize  int64         `yaml:"max_message_size"` // WebSocket read limit

	Metrics  bool   `yaml:"metrics"`   // CT_METRICS
	LogLevel string `yaml:"log_level"` // CT_LOG_LEVEL debug|info|warn|error
	LogJSON  bool   `yaml:"log_json"`  // CT_LOG_JSON
}

// Default returns the built-in defaults.
func Default() Config {
	return Config{
		Listen:           ":8080",
		TURNPort:         3478,
		TURNPortRange:    "49152-65535",
		TURNRealm:        "crosstransfer",
		TURNCredTTL:      10 * time.Minute,
		RelayRateLimit:   0,
		ClaimRatePerIP:   1,
		ClaimBurstPerIP:  5,
		ClaimRateGlobal:  200,
		ClaimBurstGlobal: 400,
		ClaimFailDelay:   500 * time.Millisecond,
		HeartbeatSec:     30,
		DefaultShareTTL:  10 * time.Minute,
		MaxOnceTTL:       24 * time.Hour,
		MaxOpenTTL:       24 * time.Hour,
		MaxMessageSize:   1 << 20,
		LogLevel:         "info",
	}
}

// Load builds the configuration: defaults ← YAML (CT_CONFIG) ← environment.
func Load() (Config, error) {
	cfg := Default()
	if path := os.Getenv("CT_CONFIG"); path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return cfg, fmt.Errorf("read config: %w", err)
		}
		if err := yaml.Unmarshal(data, &cfg); err != nil {
			return cfg, fmt.Errorf("parse config: %w", err)
		}
	}
	if err := cfg.applyEnv(os.LookupEnv); err != nil {
		return cfg, err
	}
	return cfg, cfg.Validate()
}

// applyEnv overlays environment variables. lookup is injectable for tests.
func (c *Config) applyEnv(lookup func(string) (string, bool)) error {
	str := func(key string, dst *string) {
		if v, ok := lookup(key); ok {
			*dst = v
		}
	}
	integer := func(key string, dst *int) error {
		if v, ok := lookup(key); ok {
			n, err := strconv.Atoi(v)
			if err != nil {
				return fmt.Errorf("%s: %w", key, err)
			}
			*dst = n
		}
		return nil
	}
	float := func(key string, dst *float64) error {
		if v, ok := lookup(key); ok {
			f, err := strconv.ParseFloat(v, 64)
			if err != nil {
				return fmt.Errorf("%s: %w", key, err)
			}
			*dst = f
		}
		return nil
	}
	dur := func(key string, dst *time.Duration) error {
		if v, ok := lookup(key); ok {
			d, err := time.ParseDuration(v)
			if err != nil {
				return fmt.Errorf("%s: %w", key, err)
			}
			*dst = d
		}
		return nil
	}
	boolean := func(key string, dst *bool) error {
		if v, ok := lookup(key); ok {
			b, err := strconv.ParseBool(v)
			if err != nil {
				return fmt.Errorf("%s: %w", key, err)
			}
			*dst = b
		}
		return nil
	}

	str("CT_DOWNLOAD_URL", &c.DownloadURL)
	str("CT_ASSOCIATION_DIR", &c.AssociationDir)
	str("CT_LISTEN", &c.Listen)
	str("CT_TLS_CERT", &c.TLSCert)
	str("CT_TLS_KEY", &c.TLSKey)
	str("CT_ACME_DOMAIN", &c.ACMEDomain)
	str("CT_ACME_CACHE_DIR", &c.ACMECacheDir)
	str("CT_PUBLIC_IP", &c.PublicIP)
	if v, ok := lookup("CT_STUN_SERVERS"); ok {
		c.STUNServers = nil
		for _, s := range strings.Split(v, ",") {
			if s = strings.TrimSpace(s); s != "" {
				c.STUNServers = append(c.STUNServers, s)
			}
		}
	}
	str("CT_TURN_PORT_RANGE", &c.TURNPortRange)
	str("CT_TURN_SECRET", &c.TURNSecret)
	str("CT_TURN_REALM", &c.TURNRealm)
	str("CT_EXTERNAL_TURN", &c.ExternalTURN)
	str("CT_LOG_LEVEL", &c.LogLevel)

	for _, e := range []error{
		integer("CT_TURN_PORT", &c.TURNPort),
		integer("CT_RELAY_RATE_LIMIT", &c.RelayRateLimit),
		integer("CT_CLAIM_BURST_PER_IP", &c.ClaimBurstPerIP),
		integer("CT_CLAIM_BURST_GLOBAL", &c.ClaimBurstGlobal),
		integer("CT_HEARTBEAT_SEC", &c.HeartbeatSec),
		float("CT_CLAIM_RATE_PER_IP", &c.ClaimRatePerIP),
		float("CT_CLAIM_RATE_GLOBAL", &c.ClaimRateGlobal),
		dur("CT_TURN_CRED_TTL", &c.TURNCredTTL),
		dur("CT_CLAIM_FAIL_DELAY", &c.ClaimFailDelay),
		dur("CT_DEFAULT_SHARE_TTL", &c.DefaultShareTTL),
		dur("CT_MAX_ONCE_TTL", &c.MaxOnceTTL),
		dur("CT_MAX_OPEN_TTL", &c.MaxOpenTTL),
		boolean("CT_METRICS", &c.Metrics),
		boolean("CT_LOG_JSON", &c.LogJSON),
	} {
		if e != nil {
			return e
		}
	}
	if v, ok := lookup("CT_MAX_MESSAGE_SIZE"); ok {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return fmt.Errorf("CT_MAX_MESSAGE_SIZE: %w", err)
		}
		c.MaxMessageSize = n
	}
	return nil
}

// Validate checks cross-field constraints.
func (c *Config) Validate() error {
	if c.DownloadURL != "" {
		u, err := url.Parse(c.DownloadURL)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
			return errors.New("download_url must be an absolute HTTPS URL without credentials")
		}
	}

	if c.Listen == "" {
		return errors.New("listen address is empty")
	}
	if (c.TLSCert == "") != (c.TLSKey == "") {
		return errors.New("tls_cert and tls_key must be set together")
	}
	if c.TLSCert != "" && c.ACMEDomain != "" {
		return errors.New("tls_cert and acme_domain are mutually exclusive")
	}
	if c.EmbeddedTURNEnabled() {
		if c.PublicIP == "" {
			return errors.New("public_ip is required when the embedded TURN server is enabled (set CT_PUBLIC_IP or CT_TURN_PORT=0)")
		}
		if _, _, err := c.TURNPorts(); err != nil {
			return err
		}
	}
	if c.HeartbeatSec <= 0 {
		return errors.New("heartbeat_sec must be positive")
	}
	if c.MaxMessageSize < 4096 {
		return errors.New("max_message_size too small")
	}
	return nil
}

// EmbeddedTURNEnabled reports whether the in-process TURN server should run.
func (c *Config) EmbeddedTURNEnabled() bool {
	return c.ExternalTURN == "" && c.TURNPort > 0
}

// TURNPorts parses the relay port range.
func (c *Config) TURNPorts() (min, max uint16, err error) {
	parts := strings.SplitN(c.TURNPortRange, "-", 2)
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("turn_port_range %q: want MIN-MAX", c.TURNPortRange)
	}
	lo, err1 := strconv.Atoi(strings.TrimSpace(parts[0]))
	hi, err2 := strconv.Atoi(strings.TrimSpace(parts[1]))
	if err1 != nil || err2 != nil || lo < 1 || hi > 65535 || lo > hi {
		return 0, 0, fmt.Errorf("turn_port_range %q is invalid", c.TURNPortRange)
	}
	return uint16(lo), uint16(hi), nil
}

// TURNURI is the TURN URI advertised to clients.
func (c *Config) TURNURI() string {
	if c.ExternalTURN != "" {
		return c.ExternalTURN
	}
	if c.TURNPort > 0 && c.PublicIP != "" {
		return fmt.Sprintf("turn:%s:%d?transport=udp", c.PublicIP, c.TURNPort)
	}
	return ""
}

// STUNURIs are the STUN URIs advertised to clients.
func (c *Config) STUNURIs() []string {
	if len(c.STUNServers) > 0 {
		out := make([]string, 0, len(c.STUNServers))
		for _, s := range c.STUNServers {
			if !strings.HasPrefix(s, "stun:") {
				s = "stun:" + s
			}
			out = append(out, s)
		}
		return out
	}
	if c.TURNPort > 0 && c.PublicIP != "" {
		return []string{fmt.Sprintf("stun:%s:%d", c.PublicIP, c.TURNPort)}
	}
	return nil
}
