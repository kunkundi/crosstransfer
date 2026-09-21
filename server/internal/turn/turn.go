// Package turn hosts the embedded TURN server (pion/turn) and issues
// time-limited HMAC credentials compatible with the coturn REST API
// (username = "<expiry-unix>:<user>", password = base64(HMAC-SHA1(secret, username))).
package turn

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/pion/logging"
	pionturn "github.com/pion/turn/v4"
)

// Credentials is a TURN long-term credential pair with its expiry.
type Credentials struct {
	Username  string
	Password  string
	ExpiresAt time.Time
}

// RandomSecret returns a fresh 32-byte hex secret.
func RandomSecret() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

// IssueCredentials creates REST-API-style credentials for user valid for ttl.
func IssueCredentials(secret, user string, ttl time.Duration, now time.Time) Credentials {
	exp := now.Add(ttl)
	username := strconv.FormatInt(exp.Unix(), 10) + ":" + user
	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(username))
	return Credentials{
		Username:  username,
		Password:  base64.StdEncoding.EncodeToString(mac.Sum(nil)),
		ExpiresAt: exp,
	}
}

// VerifyCredentials checks a username/password pair against secret at now.
func VerifyCredentials(secret, username, password string, now time.Time) bool {
	ts, _, ok := strings.Cut(username, ":")
	if !ok {
		return false
	}
	exp, err := strconv.ParseInt(ts, 10, 64)
	if err != nil || exp < now.Unix() {
		return false
	}
	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(username))
	want := mac.Sum(nil)
	got, err := base64.StdEncoding.DecodeString(password)
	if err != nil {
		return false
	}
	return hmac.Equal(want, got)
}

// Options configures the embedded server.
type Options struct {
	PublicIP net.IP
	ListenIP string // bind address for the listening socket and relays ("0.0.0.0")
	Port     int
	MinPort  uint16
	MaxPort  uint16
	Realm    string
	Secret   string
	Logger   *slog.Logger
}

// Server wraps a pion TURN server.
type Server struct {
	inner *pionturn.Server
	conn  net.PacketConn
	log   *slog.Logger
}

// Start binds the UDP socket and starts serving.
func Start(o Options) (*Server, error) {
	if o.PublicIP == nil {
		return nil, errors.New("turn: public IP required")
	}
	if o.ListenIP == "" {
		o.ListenIP = "0.0.0.0"
	}
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
	conn, err := net.ListenPacket("udp4", net.JoinHostPort(o.ListenIP, strconv.Itoa(o.Port)))
	if err != nil {
		return nil, fmt.Errorf("turn: listen: %w", err)
	}
	secret := o.Secret
	realm := o.Realm
	lf := &slogFactory{log: o.Logger}
	inner, err := pionturn.NewServer(pionturn.ServerConfig{
		Realm:         realm,
		LoggerFactory: lf,
		AuthHandler: func(username, r string, src net.Addr) ([]byte, bool) {
			ts, _, ok := strings.Cut(username, ":")
			if !ok {
				return nil, false
			}
			exp, err := strconv.ParseInt(ts, 10, 64)
			if err != nil || exp < time.Now().Unix() {
				return nil, false
			}
			mac := hmac.New(sha1.New, []byte(secret))
			mac.Write([]byte(username))
			pw := base64.StdEncoding.EncodeToString(mac.Sum(nil))
			return pionturn.GenerateAuthKey(username, r, pw), true
		},
		PacketConnConfigs: []pionturn.PacketConnConfig{{
			PacketConn: conn,
			RelayAddressGenerator: &pionturn.RelayAddressGeneratorPortRange{
				RelayAddress: o.PublicIP,
				Address:      o.ListenIP,
				MinPort:      o.MinPort,
				MaxPort:      o.MaxPort,
			},
		}},
	})
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("turn: %w", err)
	}
	o.Logger.Info("embedded TURN started", "listen", conn.LocalAddr().String(), "relay_ip", o.PublicIP.String(), "ports", fmt.Sprintf("%d-%d", o.MinPort, o.MaxPort))
	return &Server{inner: inner, conn: conn, log: o.Logger}, nil
}

// Close stops the server.
func (s *Server) Close() error {
	if s == nil {
		return nil
	}
	return s.inner.Close()
}

// AllocationCount reports live relay allocations.
func (s *Server) AllocationCount() int {
	if s == nil {
		return 0
	}
	return s.inner.AllocationCount()
}

// slogFactory adapts pion/logging to slog.
type slogFactory struct{ log *slog.Logger }

func (f *slogFactory) NewLogger(scope string) logging.LeveledLogger {
	return &slogLeveled{log: f.log.With("scope", "turn."+scope)}
}

type slogLeveled struct{ log *slog.Logger }

func (l *slogLeveled) Trace(msg string)                  { l.log.Debug(msg) }
func (l *slogLeveled) Tracef(f string, a ...interface{}) { l.log.Debug(fmt.Sprintf(f, a...)) }
func (l *slogLeveled) Debug(msg string)                  { l.log.Debug(msg) }
func (l *slogLeveled) Debugf(f string, a ...interface{}) { l.log.Debug(fmt.Sprintf(f, a...)) }
func (l *slogLeveled) Info(msg string)                   { l.log.Info(msg) }
func (l *slogLeveled) Infof(f string, a ...interface{})  { l.log.Info(fmt.Sprintf(f, a...)) }
func (l *slogLeveled) Warn(msg string)                   { l.log.Warn(msg) }
func (l *slogLeveled) Warnf(f string, a ...interface{})  { l.log.Warn(fmt.Sprintf(f, a...)) }
func (l *slogLeveled) Error(msg string)                  { l.log.Error(msg) }
func (l *slogLeveled) Errorf(f string, a ...interface{}) { l.log.Error(fmt.Sprintf(f, a...)) }
