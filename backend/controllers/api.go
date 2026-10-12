package controllers

import (
	"agent-conductor/backend/config"
	"agent-conductor/backend/dao"
	"agent-conductor/backend/service"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/gorilla/mux"
	"gorm.io/gorm"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

type API struct {
	Config   config.Config
	Auth     service.Auth
	Relay    service.Relay
	mu       sync.Mutex
	attempts map[string][]time.Time
	streams  map[string]int
}

func New(c config.Config, db *gorm.DB) *API {
	return &API{Config: c, Auth: service.Auth{DB: db}, Relay: service.Relay{DB: db}, attempts: map[string][]time.Time{}, streams: map[string]int{}}
}
func (a *API) Router() http.Handler {
	r := mux.NewRouter()
	r.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		sql, err := a.Auth.DB.DB()
		if err != nil || sql.PingContext(r.Context()) != nil {
			write(w, 503, map[string]any{"error": "database unavailable"})
			return
		}
		write(w, 200, map[string]any{"ok": true})
	}).Methods("GET")
	r.HandleFunc("/api/v1/auth/login", a.login).Methods("POST")
	r.HandleFunc("/api/v1/auth/options", func(w http.ResponseWriter, r *http.Request) {
		write(w, 200, map[string]any{"signup_enabled": a.Config.AllowSignup})
	}).Methods("GET")
	r.HandleFunc("/api/v1/auth/register", a.register).Methods("POST")
	r.HandleFunc("/api/v1/auth/session", a.browser(a.session)).Methods("GET")
	r.HandleFunc("/api/v1/auth/logout", a.browser(a.logout)).Methods("POST")
	r.HandleFunc("/api/v1/devices", a.browser(a.devices)).Methods("GET", "POST")
	r.HandleFunc("/api/v1/devices/{device}", a.browser(a.device)).Methods("GET", "DELETE")
	r.HandleFunc("/api/v1/devices/{device}/runs/{run}", a.browser(a.run)).Methods("GET")
	r.HandleFunc("/api/v1/devices/{device}/commands", a.browser(a.command)).Methods("POST")
	r.HandleFunc("/api/v1/events", a.browser(a.events)).Methods("GET")
	r.HandleFunc("/api/v1/device/workspaces", a.deviceAuth(a.workspaces)).Methods("PUT")
	r.HandleFunc("/api/v1/device/events", a.deviceAuth(a.upload)).Methods("POST")
	r.HandleFunc("/api/v1/device/commands", a.deviceAuth(a.poll)).Methods("GET")
	r.HandleFunc("/api/v1/device/commands/{command}/ack", a.deviceAuth(a.ack)).Methods("POST")
	r.HandleFunc("/api/v1/device/revoke", a.deviceAuth(a.revoke)).Methods("POST")
	return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		requestURL := request
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Request-ID", service.ID())
		if strings.HasPrefix(a.Config.PublicOrigin, "https:") {
			w.Header().Set("Strict-Transport-Security", "max-age=31536000")
		}
		// Credentialed browser traffic is same-origin. Device endpoints use only bearer authentication.
		if origin := requestURL.Header.Get("Origin"); origin != "" && origin != a.Config.PublicOrigin {
			write(w, 403, map[string]any{"error": "origin not allowed"})
			return
		}
		r.ServeHTTP(w, requestURL)
	})
}
func write(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func decode(w http.ResponseWriter, r *http.Request, v any, limit int64) error {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	defer r.Body.Close()
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return err
	}
	if d.Decode(&struct{}{}) != io.EOF {
		return errors.New("one JSON object is required")
	}
	return nil
}
func fail(w http.ResponseWriter, err error) {
	write(w, service.ErrorStatus(err), map[string]any{"error": service.PublicError(err)})
}
func (a *API) browser(next func(http.ResponseWriter, *http.Request, *dao.User, string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie(a.Config.CookieName())
		if err != nil {
			write(w, 401, map[string]any{"error": "sign in required"})
			return
		}
		u, err := a.Auth.User(r.Context(), cookie.Value)
		if err != nil {
			write(w, 401, map[string]any{"error": "session expired; sign in again"})
			return
		}
		if r.Method != "GET" && r.Method != "HEAD" {
			want := service.CSRF(a.Config.SessionSecret, cookie.Value)
			if r.Header.Get("Origin") != a.Config.PublicOrigin || subtle.ConstantTimeCompare([]byte(r.Header.Get("X-CSRF-Token")), []byte(want)) != 1 {
				write(w, 403, map[string]any{"error": "CSRF validation failed"})
				return
			}
		}
		next(w, r, u, cookie.Value)
	}
}
func (a *API) deviceAuth(next func(http.ResponseWriter, *http.Request, *dao.Device)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			write(w, 401, map[string]any{"error": "device authentication required"})
			return
		}
		d, err := a.Relay.Device(r.Context(), strings.TrimPrefix(h, "Bearer "))
		if err != nil {
			write(w, 401, map[string]any{"error": "device revoked or credential invalid"})
			return
		}
		next(w, r, d)
	}
}
func (a *API) authGate(w http.ResponseWriter, r *http.Request, key string, limit int) bool {
	if r.Header.Get("Origin") != a.Config.PublicOrigin {
		write(w, 403, map[string]any{"error": "origin required"})
		return false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	recent := a.attempts[key][:0]
	for _, at := range a.attempts[key] {
		if now.Sub(at) < time.Minute {
			recent = append(recent, at)
		}
	}
	if len(recent) >= limit {
		w.Header().Set("Retry-After", "60")
		write(w, 429, map[string]any{"error": "too many login attempts; try again shortly"})
		return false
	}
	if len(a.attempts) > 4096 {
		for ip, ats := range a.attempts {
			if len(ats) == 0 || now.Sub(ats[len(ats)-1]) > time.Minute {
				delete(a.attempts, ip)
			}
		}
		if len(a.attempts) > 4096 {
			write(w, 429, map[string]any{"error": "try again shortly"})
			return false
		}
	}
	a.attempts[key] = append(recent, now)
	return true
}
func authIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	// Forwarded addresses are deliberately not trusted. The per-account bucket prevents
	// brute force even when the Svelte proxy makes browsers share one upstream address.
	return "ip:" + host
}

type credentials struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

func (a *API) login(w http.ResponseWriter, r *http.Request) {
	if !a.authGate(w, r, authIP(r), 120) {
		return
	}
	var in credentials
	if decode(w, r, &in, 4096) != nil {
		write(w, 400, map[string]any{"error": "invalid login request"})
		return
	}
	if !a.authGate(w, r, "account:"+service.Hash(strings.ToLower(strings.TrimSpace(in.Email))), 8) {
		return
	}
	u, err := a.Auth.Login(r.Context(), in.Email, in.Password)
	if err != nil {
		write(w, 401, map[string]any{"error": "invalid email or password"})
		return
	}
	a.signIn(w, r, u)
}
func (a *API) register(w http.ResponseWriter, r *http.Request) {
	if !a.Config.AllowSignup {
		write(w, 403, map[string]any{"error": "signup is disabled; ask the server owner for an account"})
		return
	}
	if !a.authGate(w, r, authIP(r), 120) {
		return
	}
	var in credentials
	if decode(w, r, &in, 4096) != nil {
		write(w, 400, map[string]any{"error": "invalid signup request"})
		return
	}
	if !a.authGate(w, r, "account:"+service.Hash(strings.ToLower(strings.TrimSpace(in.Email))), 8) {
		return
	}
	u, err := a.Auth.CreateUser(r.Context(), in.Email, in.Password)
	if err != nil {
		write(w, 400, map[string]any{"error": err.Error()})
		return
	}
	a.signIn(w, r, u)
}
func (a *API) signIn(w http.ResponseWriter, r *http.Request, u *dao.User) {
	// Replace an existing session at login; never adopt an incoming session identifier.
	if old, err := r.Cookie(a.Config.CookieName()); err == nil {
		a.Auth.DB.WithContext(r.Context()).Delete(&dao.Session{}, "hash = ?", service.Hash(old.Value))
	}
	token, err := a.Auth.Session(r.Context(), u.ID)
	if err != nil {
		write(w, 500, map[string]any{"error": "could not create session"})
		return
	}
	http.SetCookie(w, &http.Cookie{Name: a.Config.CookieName(), Value: token, Path: "/", MaxAge: 12 * 60 * 60, HttpOnly: true, Secure: strings.HasPrefix(a.Config.PublicOrigin, "https:"), SameSite: http.SameSiteStrictMode})
	write(w, 200, map[string]any{"user": u, "csrf": service.CSRF(a.Config.SessionSecret, token), "signup_enabled": a.Config.AllowSignup})
}
func (a *API) session(w http.ResponseWriter, r *http.Request, u *dao.User, token string) {
	write(w, 200, map[string]any{"user": u, "csrf": service.CSRF(a.Config.SessionSecret, token), "signup_enabled": a.Config.AllowSignup})
}
func (a *API) logout(w http.ResponseWriter, r *http.Request, _ *dao.User, token string) {
	if err := a.Auth.DB.WithContext(r.Context()).Delete(&dao.Session{}, "hash = ?", service.Hash(token)).Error; err != nil {
		fail(w, err)
		return
	}
	http.SetCookie(w, &http.Cookie{Name: a.Config.CookieName(), Path: "/", Value: "", MaxAge: -1, HttpOnly: true, Secure: strings.HasPrefix(a.Config.PublicOrigin, "https:"), SameSite: http.SameSiteStrictMode})
	write(w, 200, map[string]any{"ok": true})
}
func (a *API) devices(w http.ResponseWriter, r *http.Request, u *dao.User, _ string) {
	if r.Method == "GET" {
		rows := []dao.Device{}
		if err := a.Auth.DB.WithContext(r.Context()).Where("user_id = ? AND revoked_at IS NULL", u.ID).Order("created_at DESC").Find(&rows).Error; err != nil {
			fail(w, err)
			return
		}
		write(w, 200, map[string]any{"devices": rows})
		return
	}
	var in struct {
		Name       string                   `json:"name"`
		Workspaces []service.WorkspaceInput `json:"workspaces"`
	}
	if decode(w, r, &in, 16<<10) != nil {
		write(w, 400, map[string]any{"error": "invalid device request"})
		return
	}
	d, token, err := a.Relay.Enroll(r.Context(), u.ID, in.Name, in.Workspaces)
	if err != nil {
		fail(w, err)
		return
	}
	write(w, 201, map[string]any{"device": d, "token": token})
}
func (a *API) device(w http.ResponseWriter, r *http.Request, u *dao.User, _ string) {
	d, err := a.Relay.Owned(r.Context(), u.ID, mux.Vars(r)["device"])
	if err != nil {
		fail(w, err)
		return
	}
	if r.Method == "DELETE" {
		if err := a.Relay.Revoke(r.Context(), d.ID); err != nil {
			fail(w, err)
			return
		}
		write(w, 200, map[string]any{"ok": true})
		return
	}
	data, err := a.Relay.Overview(r.Context(), d.ID, r.URL.Query().Get("run_id"))
	if err != nil {
		fail(w, err)
		return
	}
	write(w, 200, data)
}
func (a *API) run(w http.ResponseWriter, r *http.Request, u *dao.User, _ string) {
	d, err := a.Relay.Owned(r.Context(), u.ID, mux.Vars(r)["device"])
	if err != nil {
		fail(w, err)
		return
	}
	data, err := a.Relay.Run(r.Context(), d.ID, mux.Vars(r)["run"])
	if err != nil {
		fail(w, err)
		return
	}
	write(w, 200, data)
}
func (a *API) command(w http.ResponseWriter, r *http.Request, u *dao.User, _ string) {
	var in struct {
		ID          string          `json:"id"`
		WorkspaceID string          `json:"workspace_id"`
		Kind        string          `json:"kind"`
		Payload     json.RawMessage `json:"payload"`
	}
	if decode(w, r, &in, 70<<10) != nil {
		write(w, 400, map[string]any{"error": "invalid command request"})
		return
	}
	c, err := a.Relay.Queue(r.Context(), u.ID, mux.Vars(r)["device"], in.WorkspaceID, in.ID, in.Kind, in.Payload)
	if err != nil {
		fail(w, err)
		return
	}
	write(w, 202, service.WireCommand(*c))
}
func (a *API) workspaces(w http.ResponseWriter, r *http.Request, d *dao.Device) {
	var in struct {
		Workspaces  []service.WorkspaceInput `json:"workspaces"`
		Connections []service.Connection     `json:"connections"`
	}
	if decode(w, r, &in, 32<<10) != nil {
		write(w, 400, map[string]any{"error": "invalid workspace advertisement"})
		return
	}
	if err := a.Relay.Workspaces(r.Context(), d.ID, in.Workspaces, in.Connections); err != nil {
		fail(w, err)
		return
	}
	write(w, 200, map[string]any{"ok": true})
}
func (a *API) upload(w http.ResponseWriter, r *http.Request, d *dao.Device) {
	var in service.Upload
	if decode(w, r, &in, 5<<20) != nil {
		write(w, 400, map[string]any{"error": "invalid event upload"})
		return
	}
	if err := a.Relay.Upload(r.Context(), d.ID, in); err != nil {
		fail(w, err)
		return
	}
	write(w, 200, map[string]any{"ok": true})
}
func (a *API) poll(w http.ResponseWriter, r *http.Request, d *dao.Device) {
	deadline := time.NewTimer(20 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		rows, err := a.Relay.Claim(r.Context(), d.ID)
		if err != nil {
			fail(w, err)
			return
		}
		if len(rows) > 0 {
			out := []any{}
			for _, c := range rows {
				out = append(out, service.WireCommand(c))
			}
			write(w, 200, map[string]any{"commands": out})
			return
		}
		select {
		case <-r.Context().Done():
			return
		case <-deadline.C:
			write(w, 200, map[string]any{"commands": []any{}})
			return
		case <-tick.C:
		}
	}
}
func (a *API) ack(w http.ResponseWriter, r *http.Request, d *dao.Device) {
	var in struct {
		Status string `json:"status"`
		Result string `json:"result"`
	}
	if decode(w, r, &in, 2048) != nil {
		write(w, 400, map[string]any{"error": "invalid acknowledgement"})
		return
	}
	if err := a.Relay.Ack(r.Context(), d.ID, mux.Vars(r)["command"], in.Status, in.Result); err != nil {
		fail(w, err)
		return
	}
	write(w, 200, map[string]any{"ok": true})
}
func (a *API) revoke(w http.ResponseWriter, r *http.Request, d *dao.Device) {
	if err := a.Relay.Revoke(r.Context(), d.ID); err != nil {
		fail(w, err)
		return
	}
	write(w, 200, map[string]any{"ok": true})
}
func sendEvent(w http.ResponseWriter, id uint64, kind string, data any) error {
	encoded, err := json.Marshal(data)
	if err != nil {
		return err
	}
	controller := http.NewResponseController(w)
	_ = controller.SetWriteDeadline(time.Now().Add(15 * time.Second))
	if _, err = fmt.Fprintf(w, "id: %d\nevent: %s\ndata: %s\n\n", id, kind, encoded); err != nil {
		return err
	}
	return controller.Flush()
}
func (a *API) events(w http.ResponseWriter, r *http.Request, u *dao.User, token string) {
	device := r.URL.Query().Get("device_id")
	selected := r.URL.Query().Get("run_id")
	if selected != "" && !service.ValidID(selected) {
		write(w, 400, map[string]any{"error": "invalid session ID"})
		return
	}
	if _, err := a.Relay.Owned(r.Context(), u.ID, device); err != nil {
		fail(w, err)
		return
	}
	key := u.ID + device
	a.mu.Lock()
	if a.streams[key] >= 3 {
		a.mu.Unlock()
		write(w, 429, map[string]any{"error": "too many live streams"})
		return
	}
	a.streams[key]++
	a.mu.Unlock()
	defer func() {
		a.mu.Lock()
		a.streams[key]--
		if a.streams[key] == 0 {
			delete(a.streams, key)
		}
		a.mu.Unlock()
	}()
	cursor, _ := strconv.ParseUint(r.Header.Get("Last-Event-ID"), 10, 64)
	if cursor == 0 {
		cursor, _ = strconv.ParseUint(r.URL.Query().Get("after"), 10, 64)
	}
	var oldest, newest uint64
	a.Auth.DB.WithContext(r.Context()).Model(&dao.Event{}).Select("COALESCE(MIN(id),0)").Where("device_id = ?", device).Scan(&oldest)
	a.Auth.DB.WithContext(r.Context()).Model(&dao.Event{}).Select("COALESCE(MAX(id),0)").Where("device_id = ?", device).Scan(&newest)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	w.Header().Set("Cache-Control", "no-store, no-transform")
	if cursor == 0 || cursor < oldest || cursor > newest {
		data, err := a.Relay.Overview(r.Context(), device, selected)
		if err != nil {
			return
		}
		cursor = data["cursor"].(uint64)
		if sendEvent(w, cursor, "snapshot", data) != nil {
			return
		}
	}
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	lastAuth := time.Now()
	lastHeartbeat := time.Now()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-tick.C:
		}
		if time.Since(lastAuth) > 2*time.Second {
			if _, err := a.Auth.User(r.Context(), token); err != nil {
				return
			}
			if _, err := a.Relay.Owned(r.Context(), u.ID, device); err != nil {
				return
			}
			lastAuth = time.Now()
		}
		var rows []dao.Event
		if err := a.Auth.DB.WithContext(r.Context()).Where("device_id = ? AND id > ?", device, cursor).Order("id").Limit(32).Find(&rows).Error; err != nil {
			log.Print("event database query failed")
			return
		}
		for _, event := range rows {
			kind := event.Kind
			var data any = json.RawMessage(event.Data)
			if kind != "run_deleted" && event.RunID != nil && *event.RunID != selected {
				var upload service.Upload
				if json.Unmarshal(event.Data, &upload) != nil {
					return
				}
				kind = "run_summary"
				data = map[string]any{"kind": kind, "run_id": upload.RunID, "workspace_id": upload.WorkspaceID, "generation": upload.Generation, "version": upload.Version, "run": upload.Summary, "summary": true}
			}
			if sendEvent(w, event.ID, kind, data) != nil {
				return
			}
			cursor = event.ID
		}
		if time.Since(lastHeartbeat) > 5*time.Second {
			var d dao.Device
			if a.Auth.DB.WithContext(r.Context()).First(&d, "id = ?", device).Error != nil {
				return
			}
			var spaces []dao.Workspace
			a.Auth.DB.WithContext(r.Context()).Where("device_id = ?", device).Find(&spaces)
			var commands []dao.Command
			a.Auth.DB.WithContext(r.Context()).Where("device_id = ?", device).Order("created_at DESC").Limit(20).Find(&commands)
			out := []any{}
			for _, c := range commands {
				out = append(out, service.WireCommand(c))
			}
			if sendEvent(w, cursor, "presence", map[string]any{"device": d, "workspaces": spaces, "connections": json.RawMessage(d.Connections), "commands": out}) != nil {
				return
			}
			lastHeartbeat = time.Now()
		}
	}
}
