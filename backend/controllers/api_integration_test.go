package controllers

import (
	"agent-conductor/backend/config"
	"agent-conductor/backend/dao"
	"agent-conductor/backend/internal/testdb"
	"agent-conductor/backend/service"
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T) (*API, http.Handler) {
	t.Helper()
	a := New(config.Config{PublicOrigin: "https://conductor.example.test", SessionSecret: strings.Repeat("s", 64), Development: false}, testdb.Open(t))
	return a, a.Router()
}
func call(t *testing.T, h http.Handler, method, path string, body any, cookie *http.Cookie, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	var data []byte
	if body != nil {
		var err error
		data, err = json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(data))
	r.RemoteAddr = "127.0.0.1:1234"
	if cookie != nil {
		r.AddCookie(cookie)
	}
	for key, value := range headers {
		r.Header.Set(key, value)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func object(t *testing.T, w *httptest.ResponseRecorder, status int) map[string]any {
	t.Helper()
	if w.Code != status {
		t.Fatalf("status %d, want %d: %s", w.Code, status, w.Body.String())
	}
	var value map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &value); err != nil {
		t.Fatal(err)
	}
	return value
}
func account(t *testing.T, a *API, h http.Handler) (*dao.User, *http.Cookie, map[string]string) {
	t.Helper()
	email := service.ID() + "@example.test"
	password := "test-password-1234"
	u, err := a.Auth.CreateUser(context.Background(), email, password)
	if err != nil {
		t.Fatal(err)
	}
	w := call(t, h, "POST", "/api/v1/auth/login", map[string]string{"email": email, "password": password}, nil, map[string]string{"Origin": a.Config.PublicOrigin})
	data := object(t, w, 200)
	cookies := w.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatal("missing session cookie")
	}
	cookie := cookies[0]
	if !cookie.HttpOnly || !cookie.Secure || cookie.SameSite != http.SameSiteStrictMode || cookie.Path != "/" || cookie.Name != "__Host-conductor-session" {
		t.Fatal("unsafe cookie", cookie.Name)
	}
	if strings.Contains(w.Body.String(), "password") || strings.Contains(w.Body.String(), cookie.Value) {
		t.Fatal("credential in response body")
	}
	return u, cookie, map[string]string{"Origin": a.Config.PublicOrigin, "X-CSRF-Token": data["csrf"].(string)}
}
func enroll(t *testing.T, a *API, user string) (*dao.Device, string, string) {
	t.Helper()
	workspace := service.ID()
	d, token, err := a.Relay.Enroll(context.Background(), user, "Fixture Mac", []service.WorkspaceInput{{ID: workspace, Label: "Fixture project"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Relay.Workspaces(context.Background(), d.ID, []service.WorkspaceInput{{ID: workspace, Label: "Fixture project"}}, nil); err != nil {
		t.Fatal(err)
	}
	return d, token, workspace
}

func TestProductionSignupHonorsOptInAndCreatesSecureSession(t *testing.T) {
	a, h := fixture(t)
	if a.Config.Development {
		t.Fatal("signup fixture must use production mode")
	}
	email, password := service.ID()+"@example.test", "signup-password-1234"
	body := map[string]string{"email": email, "password": password}
	headers := map[string]string{"Origin": a.Config.PublicOrigin}
	if object(t, call(t, h, "GET", "/api/v1/auth/options", nil, nil, nil), 200)["signup_enabled"] != false {
		t.Fatal("signup advertised when disabled")
	}
	object(t, call(t, h, "POST", "/api/v1/auth/register", body, nil, headers), 403)
	var count int64
	if err := a.Auth.DB.Model(&dao.User{}).Where("email = ?", email).Count(&count).Error; err != nil || count != 0 {
		t.Fatal("disabled signup created an account", err)
	}
	a.Config.AllowSignup = true
	if object(t, call(t, h, "GET", "/api/v1/auth/options", nil, nil, nil), 200)["signup_enabled"] != true {
		t.Fatal("enabled signup not advertised")
	}
	object(t, call(t, h, "POST", "/api/v1/auth/register", body, nil, map[string]string{"Origin": "https://attacker.test"}), 403)
	object(t, call(t, h, "POST", "/api/v1/auth/register", map[string]string{"email": email, "password": "short"}, nil, headers), 400)
	w := call(t, h, "POST", "/api/v1/auth/register", body, nil, headers)
	data := object(t, w, 200)
	cookies := w.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatal("signup did not establish a session")
	}
	cookie := cookies[0]
	if cookie.Name != "__Host-conductor-session" || !cookie.HttpOnly || !cookie.Secure || cookie.SameSite != http.SameSiteStrictMode || cookie.Path != "/" || cookie.Domain != "" {
		t.Fatal("unsafe signup session cookie")
	}
	if strings.Contains(w.Body.String(), password) || strings.Contains(w.Body.String(), "password_hash") || strings.Contains(w.Body.String(), cookie.Value) {
		t.Fatal("signup response exposed credentials")
	}
	var user dao.User
	if err := a.Auth.DB.Where("email = ?", email).First(&user).Error; err != nil {
		t.Fatal(err)
	}
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password)); err != nil {
		t.Fatal("signup password not correctly hashed", err)
	}
	object(t, call(t, h, "GET", "/api/v1/auth/session", nil, cookie, nil), 200)
	object(t, call(t, h, "POST", "/api/v1/auth/logout", map[string]any{}, cookie, headers), 403)
	headers["X-CSRF-Token"] = data["csrf"].(string)
	object(t, call(t, h, "POST", "/api/v1/auth/logout", map[string]any{}, cookie, headers), 200)
	a.Config.AllowSignup = false
	object(t, call(t, h, "POST", "/api/v1/auth/register", body, nil, headers), 403)
}

func TestBrowserAuthenticationCSRFAndLogout(t *testing.T) {
	a, h := fixture(t)
	_, cookie, headers := account(t, a, h)
	object(t, call(t, h, "GET", "/api/v1/devices", nil, nil, nil), 401)
	object(t, call(t, h, "POST", "/api/v1/devices", map[string]any{"name": "Test", "workspaces": []any{}}, cookie, nil), 403)
	object(t, call(t, h, "POST", "/api/v1/auth/logout", map[string]any{}, cookie, map[string]string{"Origin": "https://attacker.test", "X-CSRF-Token": headers["X-CSRF-Token"]}), 403)
	object(t, call(t, h, "GET", "/api/v1/auth/session", nil, cookie, nil), 200)
	object(t, call(t, h, "POST", "/api/v1/auth/logout", map[string]any{}, cookie, headers), 200)
	object(t, call(t, h, "GET", "/api/v1/auth/session", nil, cookie, nil), 401)
}

func TestDeviceCredentialsAndAccountOwnership(t *testing.T) {
	a, h := fixture(t)
	user, cookie, headers := account(t, a, h)
	_, otherCookie, otherHeaders := account(t, a, h)
	d, token, workspace := enroll(t, a, user.ID)
	object(t, call(t, h, "GET", "/api/v1/devices/"+d.ID, nil, otherCookie, nil), 404)
	command := map[string]any{"id": service.ID(), "workspace_id": workspace, "kind": "cancel", "payload": map[string]any{"run_id": service.ID()}}
	object(t, call(t, h, "POST", "/api/v1/devices/"+d.ID+"/commands", command, otherCookie, otherHeaders), 404)
	object(t, call(t, h, "GET", "/api/v1/devices", nil, nil, map[string]string{"Authorization": "Bearer " + token}), 401)
	object(t, call(t, h, "PUT", "/api/v1/device/workspaces", map[string]any{"workspaces": []any{}}, cookie, headers), 401)
	object(t, call(t, h, "PUT", "/api/v1/device/workspaces", map[string]any{"workspaces": []any{}}, nil, map[string]string{"Authorization": "Bearer " + cookie.Value}), 401)
	object(t, call(t, h, "DELETE", "/api/v1/devices/"+d.ID, nil, cookie, headers), 200)
	object(t, call(t, h, "PUT", "/api/v1/device/workspaces", map[string]any{"workspaces": []any{}}, nil, map[string]string{"Authorization": "Bearer " + token}), 401)
	if _, err := a.Relay.Claim(context.Background(), d.ID); err == nil {
		t.Fatal("revoked device claimed commands")
	}
}

func TestCommandRetriesExpiryAndAcknowledgement(t *testing.T) {
	a, h := fixture(t)
	user, cookie, headers := account(t, a, h)
	d, _, workspace := enroll(t, a, user.ID)
	id := service.ID()
	payload := map[string]any{"run_id": service.ID()}
	command := map[string]any{"id": id, "workspace_id": workspace, "kind": "cancel", "payload": payload}
	path := "/api/v1/devices/" + d.ID + "/commands"
	object(t, call(t, h, "POST", path, command, cookie, headers), 202)
	object(t, call(t, h, "POST", path, command, cookie, headers), 202)
	var count int64
	a.Auth.DB.Model(&dao.Command{}).Count(&count)
	if count != 1 {
		t.Fatal("duplicate command", count)
	}
	command["kind"] = "continue"
	object(t, call(t, h, "POST", path, command, cookie, headers), 409)
	claimed, err := a.Relay.Claim(context.Background(), d.ID)
	if err != nil || len(claimed) != 1 {
		t.Fatal("claim", claimed, err)
	}
	if rows, err := a.Relay.Claim(context.Background(), d.ID); err != nil || len(rows) != 0 {
		t.Fatal("active lease duplicated", err)
	}
	if err := a.Relay.Ack(context.Background(), d.ID, id, "delivered", "accepted"); err != nil {
		t.Fatal(err)
	}
	if err := a.Relay.Ack(context.Background(), d.ID, id, "delivered", "accepted"); err != nil {
		t.Fatal("ack retry", err)
	}
	var stored dao.Command
	a.Auth.DB.First(&stored, "id = ?", id)
	if string(stored.Payload) != "{}" {
		t.Fatal("terminal payload retained")
	}
	command["id"] = service.ID()
	object(t, call(t, h, "POST", path, command, cookie, headers), 202)
	a.Auth.DB.Model(&dao.Command{}).Where("id = ?", command["id"]).Update("expires_at", time.Now().Add(-time.Second))
	if rows, err := a.Relay.Claim(context.Background(), d.ID); err != nil || len(rows) != 0 {
		t.Fatal("expired command delivered", err)
	}
	var expired dao.Command
	a.Auth.DB.First(&expired, "id = ?", command["id"])
	if expired.Status != "expired" || string(expired.Payload) != "{}" {
		t.Fatal("expired command retained", expired.Status)
	}
	a.Auth.DB.Model(&dao.Device{}).Where("id = ?", d.ID).Update("last_seen", time.Now().Add(-time.Minute))
	command["id"] = service.ID()
	object(t, call(t, h, "POST", path, command, cookie, headers), 503)
}

func TestSnapshotsReplayAndSharingRemoval(t *testing.T) {
	a, h := fixture(t)
	user, cookie, _ := account(t, a, h)
	d, token, workspace := enroll(t, a, user.ID)
	id, generation := service.ID(), service.ID()
	auth := map[string]string{"Authorization": "Bearer " + token}
	u := service.Upload{Kind: "run_snapshot", RunID: id, WorkspaceID: workspace, Generation: generation, Version: 1, Run: json.RawMessage(`{"id":"` + id + `","text":"Hello"}`)}
	object(t, call(t, h, "POST", "/api/v1/device/events", u, nil, auth), 200)
	var first dao.Event
	a.Auth.DB.First(&first)
	u.Kind = "run_patch"
	u.Run = nil
	u.BaseVersion = 1
	u.Version = 2
	u.Changes = []service.Patch{{Op: "append", Path: []string{"text"}, Value: " 🦀"}}
	object(t, call(t, h, "POST", "/api/v1/device/events", u, nil, auth), 200)
	object(t, call(t, h, "POST", "/api/v1/device/events", u, nil, auth), 200)
	u.Version = 4
	object(t, call(t, h, "POST", "/api/v1/device/events", u, nil, auth), 409)
	u.Version = 3
	u.BaseVersion = 2
	u.WorkspaceID = service.ID()
	object(t, call(t, h, "POST", "/api/v1/device/events", u, nil, auth), 404)
	data := object(t, call(t, h, "GET", "/api/v1/devices/"+d.ID+"/runs/"+id, nil, cookie, nil), 200)
	if !strings.Contains(string(mustJSON(t, data)), "Hello 🦀") {
		t.Fatal("append missing")
	}
	server := httptest.NewServer(h)
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	r, _ := http.NewRequestWithContext(ctx, "GET", server.URL+"/api/v1/events?device_id="+d.ID+"&run_id="+id, nil)
	r.AddCookie(cookie)
	r.Header.Set("Last-Event-ID", strconv.FormatUint(first.ID, 10))
	response, err := server.Client().Do(r)
	if err != nil {
		t.Fatal(err)
	}
	scanner := bufio.NewScanner(response.Body)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	seen := false
	for scanner.Scan() {
		if scanner.Text() == "event: run_patch" {
			seen = true
			break
		}
	}
	response.Body.Close()
	if !seen {
		t.Fatal("SSE replay missing", scanner.Err())
	}
	if err := a.Relay.Workspaces(context.Background(), d.ID, nil, nil); err != nil {
		t.Fatal(err)
	}
	var count int64
	a.Auth.DB.Model(&dao.Snapshot{}).Count(&count)
	if count != 0 {
		t.Fatal("unshared history retained")
	}
	a.Auth.DB.Model(&dao.Event{}).Count(&count)
	if count != 0 {
		t.Fatal("unshared event retained")
	}
	if err := a.Relay.Upload(context.Background(), d.ID, u); !errors.Is(err, gorm.ErrRecordNotFound) {
		t.Fatal("unshared upload accepted", err)
	}
}
func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, e := json.Marshal(v)
	if e != nil {
		t.Fatal(e)
	}
	return b
}

func TestSummaryLoadingBoundsLargeHistory(t *testing.T) {
	a, h := fixture(t)
	user, cookie, _ := account(t, a, h)
	_, otherCookie, _ := account(t, a, h)
	d, _, workspace := enroll(t, a, user.ID)
	id := service.ID()
	run := map[string]any{"id": id, "title": "Large fixture", "prompt": "Large fixture", "status": "Completed", "conversation": map[string]any{"messages": []any{map[string]any{"text": strings.Repeat("x", 2<<20)}}, "coworkers": []any{}}}
	u := service.Upload{Kind: "run_snapshot", RunID: id, WorkspaceID: workspace, Generation: service.ID(), Version: 1, Run: mustJSON(t, run)}
	if err := a.Relay.Upload(context.Background(), d.ID, u); err != nil {
		t.Fatal(err)
	}
	summary := call(t, h, "GET", "/api/v1/devices/"+d.ID, nil, cookie, nil)
	object(t, summary, 200)
	if summary.Body.Len() > 16<<10 || strings.Contains(summary.Body.String(), strings.Repeat("x", 100)) {
		t.Fatal("summary included large transcript", summary.Body.Len())
	}
	full := call(t, h, "GET", "/api/v1/devices/"+d.ID+"?run_id="+id, nil, cookie, nil)
	object(t, full, 200)
	if full.Body.Len() < 2<<20 {
		t.Fatal("selected transcript missing")
	}
	object(t, call(t, h, "GET", "/api/v1/devices/"+d.ID+"/runs/"+id, nil, otherCookie, nil), 404)
}
