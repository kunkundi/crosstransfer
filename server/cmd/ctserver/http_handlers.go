package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"html/template"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"crosstransfer/server/internal/codes"
	"crosstransfer/server/internal/config"
)

var landingTemplate = template.Must(template.New("landing").Parse(landingHTML))

func RegisterPublicHTTP(mux *http.ServeMux, cfg config.Config) error {
	mux.HandleFunc("GET /r/", func(w http.ResponseWriter, r *http.Request) {
		code, err := codes.Normalize(strings.TrimPrefix(r.URL.Path, "/r/"))
		if err != nil {
			http.Error(w, "Invalid take-code", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
		_ = landingTemplate.Execute(w, struct {
			Code        string
			CanDownload bool
		}{code, cfg.DownloadURL != ""})
	})
	mux.HandleFunc("GET /download", func(w http.ResponseWriter, r *http.Request) {
		if cfg.DownloadURL == "" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		http.Redirect(w, r, cfg.DownloadURL, http.StatusSeeOther)
	})
	if cfg.AssociationDir == "" {
		return nil
	}
	info, err := os.Stat(cfg.AssociationDir)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("association_dir must be an accessible directory")
	}
	for _, name := range []string{"apple-app-site-association", "assetlinks.json"} {
		data, err := os.ReadFile(filepath.Join(cfg.AssociationDir, name))
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return fmt.Errorf("association %s: %w", name, err)
		}
		if !json.Valid(data) {
			return fmt.Errorf("association %s is not valid JSON", name)
		}
		mux.HandleFunc("GET /.well-known/"+name, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("X-Content-Type-Options", "nosniff")
			w.Header().Set("Cache-Control", "public, max-age=3600")
			_, _ = w.Write(data)
		})
	}
	return nil
}

// This local liveness probe deliberately does not validate the leaf certificate:
// it must work for operator-provided certificates without an installed local CA. It
// carries no credentials or file data. Client transfers always verify WSS peers.
func ProbeHealth(cfg config.Config) int {
	host, port, err := net.SplitHostPort(cfg.Listen)
	if err != nil {
		return 1
	}
	if host == "" || host == "0.0.0.0" {
		host = "127.0.0.1"
	}
	if host == "::" {
		host = "::1"
	}
	scheme := "http"
	if cfg.TLSCert != "" || cfg.ACMEDomain != "" {
		scheme = "https"
	}
	transport := &http.Transport{TLSClientConfig: &tls.Config{
		InsecureSkipVerify: true, ServerName: cfg.ACMEDomain, MinVersion: tls.VersionTLS12,
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Timeout: 3 * time.Second, Transport: transport,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Get(scheme + "://" + net.JoinHostPort(host, port) + "/healthz")
	if err != nil {
		return 1
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

const landingHTML = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CrossTransfer</title>
<style>body{font-family:system-ui,sans-serif;margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center;background:#f6f7f9;color:#1a1a1a}
main{text-align:center;padding:32px;max-width:420px}code{font-size:1.6em;letter-spacing:.12em;display:block;margin:16px 0}
a.btn{display:inline-block;margin:8px;padding:12px 20px;border-radius:8px;background:#2563eb;color:#fff;text-decoration:none}</style></head>
<body><main><h1>CrossTransfer</h1><p>Take-code / 取件码</p><code>{{.Code}}</code>
<a class="btn" href="crosstransfer://r/{{.Code}}">Open in app / 用 App 打开</a>
{{if .CanDownload}}<p><a href="/download">Download CrossTransfer / 下载</a></p>{{end}}</main></body></html>
`
