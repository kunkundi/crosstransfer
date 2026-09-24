package notification

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"crosstransfer/server/internal/signal"
	"github.com/coder/websocket"
)

func TestStorePersistenceRetentionAndFailure(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "notifications.json")
	var snapshots [][]byte
	s, err := Open(path, func(data []byte) { snapshots = append(snapshots, data) })
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < Limit+1; i++ {
		if _, err := s.Create(Draft{"通知", "正文\n第二行", "info"}); err != nil {
			t.Fatal(err)
		}
	}
	if len(s.List()) != Limit {
		t.Fatal("retention limit")
	}
	newest := s.List()[0]
	if err := s.Revoke(newest.ID); err != nil {
		t.Fatal(err)
	}
	var snapshot struct {
		Items []Item `json:"items"`
	}
	if err := json.Unmarshal(snapshots[len(snapshots)-1], &snapshot); err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Items) != Limit-1 {
		t.Fatal("revoked item still delivered")
	}
	restored, err := Open(path, nil)
	if err != nil || len(restored.List()) != Limit || restored.List()[0].RevokedAt == 0 {
		t.Fatal("restart lost state", err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatalf("permissions: %v", info.Mode())
	}
	// Replacing a directory must fail without mutating memory or broadcasting.
	s.path = t.TempDir()
	count := len(snapshots)
	if _, err := s.Create(Draft{"失败", "不能下发", "important"}); err == nil {
		t.Fatal("expected persistence error")
	}
	if len(snapshots) != count || s.List()[0].ID != newest.ID {
		t.Fatal("failed write was published")
	}
	if err := os.WriteFile(path, []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(path, nil); err == nil {
		t.Fatal("corrupt store accepted")
	}
}

func TestStoreConcurrentPublish(t *testing.T) {
	var last []byte
	s, err := Open(filepath.Join(t.TempDir(), "notifications.json"), func(data []byte) { last = data })
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := s.Create(Draft{"标题", "正文", "info"}); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	var snapshot struct {
		Items []Item `json:"items"`
	}
	if err := json.Unmarshal(last, &snapshot); err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Items) != 20 || snapshot.Items[0].ID != s.List()[0].ID {
		t.Fatal("snapshot out of order")
	}
}

func TestAdminAuthValidationAndWebSocketDelivery(t *testing.T) {
	hub := signal.NewHub(signal.Options{})
	store, err := Open(filepath.Join(t.TempDir(), "notifications.json"), hub.SetNotifications)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	token := strings.Repeat("a", 32)
	Register(mux, token, store)
	mux.Handle("/ws", signal.ServeWS(hub, signal.WSOptions{}))
	srv := httptest.NewServer(mux)
	defer srv.Close()
	request := func(method, path, body, credential string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		if credential != "" {
			req.Header.Set("Authorization", "Bearer "+credential)
		}
		res := httptest.NewRecorder()
		mux.ServeHTTP(res, req)
		return res
	}
	for _, method := range []string{"GET", "POST", "DELETE"} {
		for _, credential := range []string{"", "wrong"} {
			if r := request(method, "/admin/api/notifications", `{}`, credential); r.Code != 401 {
				t.Fatal("auth bypass", r.Code)
			}
		}
	}
	page := request("GET", "/admin/", "", "")
	if page.Code != 200 || !strings.Contains(page.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") || strings.Contains(page.Body.String(), token) {
		t.Fatal("unsafe console")
	}
	for _, body := range []string{`{}`, `{"title":"x","body":"y","level":"bad"}`, `{"title":"x","body":"y","level":"info","unknown":1}`, `{"title":"x","body":"y","level":"info"}{}`, `{"title":" ","body":"y","level":"info"}`, `{"title":"x","body":"` + strings.Repeat("x", 2001) + `","level":"info"}`} {
		if r := request("POST", "/admin/api/notifications", body, token); r.Code != 400 {
			t.Fatal("accepted invalid draft", r.Code)
		}
	}
	crossSite := httptest.NewRequest("POST", "/admin/api/notifications", strings.NewReader(`{}`))
	crossSite.Header.Set("Authorization", "Bearer "+token)
	crossSite.Header.Set("Sec-Fetch-Site", "cross-site")
	forbidden := httptest.NewRecorder()
	mux.ServeHTTP(forbidden, crossSite)
	if forbidden.Code != 403 {
		t.Fatal("cross-site request accepted")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	connect := func(optIn bool) *websocket.Conn {
		conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http")+"/ws", nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.CloseNow() })
		hello, _ := json.Marshal(map[string]any{"type": "hello", "proto": 1, "notifications": optIn})
		if err := conn.Write(ctx, websocket.MessageText, hello); err != nil {
			t.Fatal(err)
		}
		return conn
	}
	read := func(conn *websocket.Conn, typ string) map[string]any {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var value map[string]any
		if err := json.Unmarshal(data, &value); err != nil {
			t.Fatal(err)
		}
		if value["type"] != typ {
			t.Fatalf("wanted %s, got %s", typ, data)
		}
		return value
	}
	online := connect(true)
	read(online, "welcome")
	read(online, "notifications")
	legacy := connect(false)
	read(legacy, "welcome")
	published := request("POST", "/admin/api/notifications", `{"title":"<script>alert(1)</script>","body":"正文","level":"important"}`, token)
	if published.Code != 201 {
		t.Fatal(published.Body.String())
	}
	var item Item
	if err := json.Unmarshal(published.Body.Bytes(), &item); err != nil {
		t.Fatal(err)
	}
	check := func(conn *websocket.Conn, count int) {
		items := read(conn, "notifications")["items"].([]any)
		if len(items) != count {
			t.Fatalf("wanted %d items: %v", count, items)
		}
		if count > 0 && items[0].(map[string]any)["id"] != item.ID {
			t.Fatal("wrong notification")
		}
	}
	check(online, 1)
	reconnect := connect(true)
	read(reconnect, "welcome")
	check(reconnect, 1)
	if r := request("DELETE", "/admin/api/notifications/"+item.ID, "", token); r.Code != 204 {
		t.Fatal(r.Code)
	}
	check(online, 0)
	check(reconnect, 0)
	// A legacy peer must still receive pong as its next frame, not announcements.
	if err := legacy.Write(ctx, websocket.MessageText, []byte(`{"type":"ping"}`)); err != nil {
		t.Fatal(err)
	}
	read(legacy, "pong")
	list := request("GET", "/admin/api/notifications", "", token)
	if list.Code != 200 || !strings.Contains(list.Body.String(), "revoked_at") {
		t.Fatal("missing history")
	}
	if r := request("DELETE", "/admin/api/notifications/missing", "", token); r.Code != 404 {
		t.Fatal(r.Code)
	}
	disabled := http.NewServeMux()
	Register(disabled, "", store)
	result := httptest.NewRecorder()
	disabled.ServeHTTP(result, httptest.NewRequest("GET", "/admin/", nil))
	if result.Code != 404 {
		t.Fatal("disabled console is exposed")
	}
}
