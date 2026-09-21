// Command ctserver is the CrossTransfer signaling / take-code / TURN / relay
// server. It is stateless across restarts and keeps everything in memory.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"crosstransfer/server/internal/config"
	"crosstransfer/server/internal/metrics"
	sig "crosstransfer/server/internal/signal"
	"crosstransfer/server/internal/turn"
	"golang.org/x/crypto/acme/autocert"
)

var version = "dev"

func main() {
	// `ctserver -healthz` probes a running instance (used by container healthchecks).
	if len(os.Args) > 1 && os.Args[1] == "-healthz" {
		os.Exit(healthz())
	}
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "ctserver:", err)
		os.Exit(1)
	}
}

func healthz() int {
	cfg, err := config.Load()
	if err != nil {
		return 1
	}
	return ProbeHealth(cfg)
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	log := newLogger(cfg)
	slog.SetDefault(log)

	if cfg.TURNSecret == "" {
		cfg.TURNSecret, err = turn.RandomSecret()
		if err != nil {
			return err
		}
		if cfg.ExternalTURN != "" {
			log.Warn("CT_TURN_SECRET is empty but an external TURN is configured; issued credentials will not validate")
		} else if cfg.EmbeddedTURNEnabled() {
			log.Info("generated ephemeral TURN secret (set CT_TURN_SECRET to pin it)")
		}
	}

	var turnSrv *turn.Server
	if cfg.EmbeddedTURNEnabled() {
		ip := net.ParseIP(cfg.PublicIP)
		if ip == nil {
			return fmt.Errorf("CT_PUBLIC_IP %q is not an IP address", cfg.PublicIP)
		}
		lo, hi, _ := cfg.TURNPorts()
		turnSrv, err = turn.Start(turn.Options{
			PublicIP: ip,
			Port:     cfg.TURNPort,
			MinPort:  lo,
			MaxPort:  hi,
			Realm:    cfg.TURNRealm,
			Secret:   cfg.TURNSecret,
			Logger:   log,
		})
		if err != nil {
			return err
		}
		defer turnSrv.Close()
	}

	hub := sig.NewHub(sig.Options{
		STUNURIs:         cfg.STUNURIs(),
		TURNURI:          cfg.TURNURI(),
		TURNSecret:       cfg.TURNSecret,
		TURNCredTTL:      cfg.TURNCredTTL,
		HeartbeatSec:     cfg.HeartbeatSec,
		DefaultShareTTL:  cfg.DefaultShareTTL,
		MaxOnceTTL:       cfg.MaxOnceTTL,
		MaxOpenTTL:       cfg.MaxOpenTTL,
		ClaimRatePerIP:   cfg.ClaimRatePerIP,
		ClaimBurstPerIP:  cfg.ClaimBurstPerIP,
		ClaimRateGlobal:  cfg.ClaimRateGlobal,
		ClaimBurstGlobal: cfg.ClaimBurstGlobal,
		ClaimFailDelay:   cfg.ClaimFailDelay,
		RelayRateLimit:   cfg.RelayRateLimit,
		Logger:           log,
	})

	mux := http.NewServeMux()
	mux.Handle("/ws", sig.ServeWS(hub, sig.WSOptions{
		MaxMessageSize: cfg.MaxMessageSize,
		HeartbeatSec:   cfg.HeartbeatSec,
		TrustProxy:     os.Getenv("CT_TRUST_PROXY") == "1",
		Logger:         log,
	}))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		st := hub.Stats()
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"ok":true,"version":%q,"peers":%d,"shares":%d,"sessions":%d,"turn_allocations":%d}`+"\n",
			version, st.Peers, st.Shares, st.Sessions, turnSrv.AllocationCount())
	})
	if cfg.Metrics {
		mux.Handle("/metrics", metrics.Handler(hub, turnSrv))
	}
	if err := RegisterPublicHTTP(mux, cfg); err != nil {
		return err
	}

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelWarn),
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		t := time.NewTicker(15 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if n := hub.Sweep(); n > 0 {
					log.Debug("swept expired shares", "count", n)
				}
			}
		}
	}()

	errCh := make(chan error, 1)
	go func() { errCh <- serve(srv, cfg, log) }()
	log.Info("ctserver started", "version", version, "listen", cfg.Listen, "tls", cfg.TLSCert != "" || cfg.ACMEDomain != "", "turn", cfg.TURNURI(), "stun", cfg.STUNURIs())

	select {
	case <-ctx.Done():
		log.Info("shutting down")
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	}
	hub.Shutdown()
	sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return srv.Shutdown(sctx)
}

func serve(srv *http.Server, cfg config.Config, log *slog.Logger) error {
	switch {
	case cfg.ACMEDomain != "":
		cache := cfg.ACMECacheDir
		if cache == "" {
			cache = "/var/lib/ctserver/acme"
		}
		m := &autocert.Manager{
			Prompt:     autocert.AcceptTOS,
			HostPolicy: autocert.HostWhitelist(cfg.ACMEDomain),
			Cache:      autocert.DirCache(cache),
		}
		srv.TLSConfig = m.TLSConfig()
		// ACME HTTP-01 fallback on :80 when we are the only service there.
		go func() {
			if err := http.ListenAndServe(":80", m.HTTPHandler(nil)); err != nil {
				log.Warn("acme http-01 listener", "err", err)
			}
		}()
		return srv.ListenAndServeTLS("", "")
	case cfg.TLSCert != "":
		srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
		return srv.ListenAndServeTLS(cfg.TLSCert, cfg.TLSKey)
	default:
		return srv.ListenAndServe()
	}
}

func newLogger(cfg config.Config) *slog.Logger {
	var level slog.Level
	switch strings.ToLower(cfg.LogLevel) {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	default:
		level = slog.LevelInfo
	}
	opts := &slog.HandlerOptions{Level: level}
	if cfg.LogJSON {
		return slog.New(slog.NewJSONHandler(os.Stdout, opts))
	}
	return slog.New(slog.NewTextHandler(os.Stdout, opts))
}
