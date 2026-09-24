package notification

import (
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
)

//go:embed web/*
var assets embed.FS

// Register exposes a static console and authenticated JSON API. Tokens stay in
// browser memory; no cookies, URL credentials or cross-origin access are used.
func Register(mux *http.ServeMux, token string, store *Store) {
	if token == "" {
		return
	}
	want := sha256.Sum256([]byte(token))
	api := http.NewServeMux()
	api.HandleFunc("GET /admin/api/notifications", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"items": store.List()})
	})
	api.HandleFunc("POST /admin/api/notifications", func(w http.ResponseWriter, r *http.Request) {
		if strings.Split(r.Header.Get("Content-Type"), ";")[0] != "application/json" {
			http.Error(w, "请使用 JSON 请求", http.StatusUnsupportedMediaType)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 24<<10)
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		var d Draft
		if err := decoder.Decode(&d); err != nil {
			http.Error(w, "通知格式错误或内容过长", http.StatusBadRequest)
			return
		}
		if decoder.Decode(new(any)) != io.EOF {
			http.Error(w, "通知格式错误", http.StatusBadRequest)
			return
		}
		if err := d.Validate(); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		item, err := store.Create(d)
		if err != nil {
			StorageError(w, err)
			return
		}
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(item)
		slog.Info("notification published", "id", item.ID)
	})
	api.HandleFunc("DELETE /admin/api/notifications/{id}", func(w http.ResponseWriter, r *http.Request) {
		err := store.Revoke(r.PathValue("id"))
		if errors.Is(err, ErrNotFound) {
			http.Error(w, "通知不存在", http.StatusNotFound)
			return
		}
		if err != nil {
			StorageError(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
		slog.Info("notification revoked", "id", r.PathValue("id"))
	})
	mux.Handle("/admin/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
		if strings.HasPrefix(r.URL.Path, "/admin/api/") {
			auth := r.Header.Get("Authorization")
			got := sha256.Sum256([]byte(strings.TrimPrefix(auth, "Bearer ")))
			if !strings.HasPrefix(auth, "Bearer ") || subtle.ConstantTimeCompare(got[:], want[:]) != 1 {
				w.Header().Set("WWW-Authenticate", "Bearer")
				http.Error(w, "管理密钥无效，请重新登录", http.StatusUnauthorized)
				return
			}
			if r.Header.Get("Sec-Fetch-Site") == "cross-site" {
				http.Error(w, "不允许跨站请求", http.StatusForbidden)
				return
			}
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			api.ServeHTTP(w, r)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}
		name, contentType := "", ""
		switch r.URL.Path {
		case "/admin/":
			name, contentType = "index.html", "text/html; charset=utf-8"
		case "/admin/admin.js":
			name, contentType = "admin.js", "text/javascript; charset=utf-8"
		case "/admin/admin.css":
			name, contentType = "admin.css", "text/css; charset=utf-8"
		default:
			http.NotFound(w, r)
			return
		}
		data, _ := assets.ReadFile("web/" + name)
		w.Header().Set("Content-Type", contentType)
		if r.Method != http.MethodHead {
			_, _ = w.Write(data)
		}
	}))
}

func StorageError(w http.ResponseWriter, err error) {
	slog.Error("notification persistence failed", "err", err)
	http.Error(w, "通知保存失败，请检查服务端存储后重试", http.StatusInternalServerError)
}
