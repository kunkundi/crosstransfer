package main

import (
	"crypto/tls"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"crosstransfer/server/internal/config"
)

func TestLandingRejectsMarkupAndOnlyRendersNormalizedCodes(t *testing.T) {
	mux := http.NewServeMux()
	if err := RegisterPublicHTTP(mux, config.Config{DownloadURL: "https://example.test/download"}); err != nil {
		t.Fatal(err)
	}
	for _, code := range []string{"<script>alert(1)</script>", `" onclick="alert(1)`, "MXT3XF8SK2extra", ""} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("GET", "/r/"+url.PathEscape(code), nil))
		if w.Code != http.StatusBadRequest || strings.Contains(w.Body.String(), "<script>") {
			t.Fatalf("%q: %d %s", code, w.Code, w.Body.String())
		}
	}
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/r/mxt3x-f8sk2", nil))
	if w.Code != 200 || !strings.Contains(w.Body.String(), `href="crosstransfer://r/MXT3XF8SK2"`) {
		t.Fatal(w.Code, w.Body.String())
	}
	if w.Header().Get("Referrer-Policy") != "no-referrer" || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal(w.Header())
	}
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/download?next=https://attacker.test", nil))
	if w.Code != 303 || w.Header().Get("Location") != "https://example.test/download" {
		t.Fatal(w.Code, w.Header())
	}
}

func TestAssociationRoutesServeOnlyConfiguredJSON(t *testing.T) {
	root := t.TempDir()
	aasa := `{"applinks":{"details":[]}}`
	assets := `[{"relation":["delegate_permission/common.handle_all_urls"]}]`
	for name, data := range map[string]string{"apple-app-site-association": aasa, "assetlinks.json": assets, "private.json": `{"secret":true}`} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	mux := http.NewServeMux()
	if err := RegisterPublicHTTP(mux, config.Config{AssociationDir: root}); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{"apple-app-site-association": aasa, "assetlinks.json": assets} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("GET", "/.well-known/"+name, nil))
		if w.Code != 200 || w.Header().Get("Content-Type") != "application/json" || w.Body.String() != body {
			t.Fatal(w.Code, w.Body.String())
		}
	}
	for _, path := range []string{"/.well-known/private.json", "/download"} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 404 {
			t.Fatal(path, w.Code)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "assetlinks.json"), []byte("broken JSON"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := RegisterPublicHTTP(http.NewServeMux(), config.Config{AssociationDir: root}); err == nil {
		t.Fatal("invalid association JSON must fail startup")
	}
}

func TestHealthProbeUsesACMESNIAndRejectsRedirects(t *testing.T) {
	names := make(chan string, 1)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/healthz" {
			t.Error(r.URL.Path)
		}
		w.WriteHeader(200)
	}))
	server.TLS = &tls.Config{GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) { names <- hello.ServerName; return nil, nil }}
	server.StartTLS()
	defer server.Close()
	cfg := config.Config{Listen: strings.TrimPrefix(server.URL, "https://"), ACMEDomain: "files.example.test"}
	if ProbeHealth(cfg) != 0 {
		t.Fatal("TLS health failed")
	}
	if name := <-names; name != cfg.ACMEDomain {
		t.Fatal(name)
	}
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "http://127.0.0.1:1", 302) }))
	defer redirect.Close()
	if ProbeHealth(config.Config{Listen: strings.TrimPrefix(redirect.URL, "http://")}) != 1 {
		t.Fatal("redirect must not be healthy")
	}
}

func TestHealthCommandHonorsYAML(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	defer server.Close()
	path := filepath.Join(t.TempDir(), "server.yaml")
	if err := os.WriteFile(path, []byte(fmt.Sprintf("listen: %q\nturn_port: 0\n", strings.TrimPrefix(server.URL, "http://"))), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CT_CONFIG", path)
	if healthz() != 0 {
		t.Fatal("YAML-configured server is healthy")
	}
}
