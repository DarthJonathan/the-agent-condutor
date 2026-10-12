package service

import (
	"agent-conductor/backend/dao"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"strconv"
	"time"
)

var ErrConflict = errors.New("conflicting request or snapshot version")
var ErrOffline = errors.New("device is offline; reconnect it before sending commands")

type Relay struct{ DB *gorm.DB }
type WorkspaceInput struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}
type Connection struct {
	Provider  string `json:"provider"`
	Model     string `json:"model"`
	Effort    string `json:"effort"`
	Available bool   `json:"available"`
}
type Upload struct {
	Kind        string          `json:"kind"`
	RunID       string          `json:"run_id"`
	WorkspaceID string          `json:"workspace_id"`
	Generation  string          `json:"generation"`
	Version     uint64          `json:"version"`
	BaseVersion uint64          `json:"base_version"`
	Run         json.RawMessage `json:"run,omitempty"`
	Changes     []Patch         `json:"changes,omitempty"`
	Summary     json.RawMessage `json:"summary,omitempty"`
}
type Patch struct {
	Op    string   `json:"op"`
	Path  []string `json:"path"`
	Value any      `json:"value,omitempty"`
}

func (s Relay) Device(ctx context.Context, token string) (*dao.Device, error) {
	if len(token) != 47 || token[:4] != "cdv_" {
		return nil, errors.New("unauthorized")
	}
	var d dao.Device
	return &d, s.DB.WithContext(ctx).Where("token_hash = ? AND revoked_at IS NULL", Hash(token)).First(&d).Error
}
func (s Relay) Owned(ctx context.Context, user, id string) (*dao.Device, error) {
	if !ValidID(id) {
		return nil, gorm.ErrRecordNotFound
	}
	var d dao.Device
	return &d, s.DB.WithContext(ctx).Where("id = ? AND user_id = ? AND revoked_at IS NULL", id, user).First(&d).Error
}
func (s Relay) Enroll(ctx context.Context, user, name string, spaces []WorkspaceInput) (*dao.Device, string, error) {
	if len(name) < 1 || len(name) > 80 {
		return nil, "", errors.New("device name must contain 1–80 bytes")
	}
	if err := validateSpaces(spaces); err != nil {
		return nil, "", err
	}
	token := "cdv_" + Token()
	d := dao.Device{ID: ID(), UserID: user, Name: name, TokenHash: Hash(token), CreatedAt: time.Now().UTC(), Connections: []byte("[]")}
	err := s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var account dao.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&account, "id = ?", user).Error; err != nil {
			return err
		}
		var count int64
		if err := tx.Model(&dao.Device{}).Where("user_id = ? AND revoked_at IS NULL", user).Count(&count).Error; err != nil {
			return err
		}
		if count >= 10 {
			return errors.New("device limit reached; revoke an old device")
		}
		if err := tx.Create(&d).Error; err != nil {
			return err
		}
		for _, w := range spaces {
			if err := tx.Create(&dao.Workspace{ID: w.ID, DeviceID: d.ID, Label: w.Label}).Error; err != nil {
				return err
			}
		}
		return nil
	})
	return &d, token, err
}
func validateSpaces(spaces []WorkspaceInput) error {
	if len(spaces) > 50 {
		return errors.New("share at most 50 workspaces")
	}
	seen := map[string]bool{}
	for _, w := range spaces {
		if !ValidID(w.ID) || seen[w.ID] || len(w.Label) < 1 || len(w.Label) > 160 {
			return errors.New("invalid workspace IDs or labels")
		}
		seen[w.ID] = true
	}
	return nil
}
func (s Relay) Workspaces(ctx context.Context, device string, spaces []WorkspaceInput, connections []Connection) error {
	if err := validateSpaces(spaces); err != nil {
		return err
	}
	if len(connections) > 6 {
		return errors.New("too many connections")
	}
	encoded, _ := json.Marshal(connections)
	return s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var d dao.Device
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND revoked_at IS NULL", device).First(&d).Error; err != nil {
			return err
		}
		ids := make([]string, 0, len(spaces))
		for _, w := range spaces {
			ids = append(ids, w.ID)
		}
		var removed []dao.Workspace
		q := tx.Where("device_id = ?", device)
		if len(ids) > 0 {
			q = q.Where("id NOT IN ?", ids)
		}
		if err := q.Find(&removed).Error; err != nil {
			return err
		}
		for _, w := range removed {
			var runs []string
			if err := tx.Model(&dao.Snapshot{}).Where("device_id = ? AND workspace_id = ?", device, w.ID).Pluck("run_id", &runs).Error; err != nil {
				return err
			}
			if len(runs) > 0 {
				if err := tx.Where("device_id = ? AND run_id IN ?", device, runs).Delete(&dao.Event{}).Error; err != nil {
					return err
				}
			}
			if err := tx.Where("device_id = ? AND workspace_id = ?", device, w.ID).Delete(&dao.Snapshot{}).Error; err != nil {
				return err
			}
			if err := tx.Where("device_id = ? AND workspace_id = ?", device, w.ID).Delete(&dao.Command{}).Error; err != nil {
				return err
			}
			if err := tx.Where("device_id = ? AND id = ?", device, w.ID).Delete(&dao.Workspace{}).Error; err != nil {
				return err
			}
		}
		for _, w := range spaces {
			row := dao.Workspace{ID: w.ID, DeviceID: device, Label: w.Label}
			if err := tx.Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "id"}, {Name: "device_id"}}, DoUpdates: clause.AssignmentColumns([]string{"label"})}).Create(&row).Error; err != nil {
				return err
			}
		}
		return tx.Model(&d).Updates(map[string]any{"connections": encoded, "last_seen": time.Now().UTC()}).Error
	})
}
func (s Relay) Revoke(ctx context.Context, device string) error {
	return s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&dao.Device{}).Where("id = ?", device).Update("revoked_at", time.Now().UTC()).Error; err != nil {
			return err
		}
		if err := tx.Model(&dao.Command{}).Where("device_id = ? AND status IN ?", device, []string{"queued", "leased"}).Updates(map[string]any{"status": "revoked", "payload": []byte("{}")}).Error; err != nil {
			return err
		}
		// A revoked pairing no longer retains a cloud copy of the Mac's content.
		if err := tx.Where("device_id = ?", device).Delete(&dao.Snapshot{}).Error; err != nil {
			return err
		}
		if err := tx.Where("device_id = ?", device).Delete(&dao.Event{}).Error; err != nil {
			return err
		}
		if err := tx.Where("device_id = ?", device).Delete(&dao.Workspace{}).Error; err != nil {
			return err
		}
		return nil
	})
}
func (s Relay) Queue(ctx context.Context, user, device, workspace, id, kind string, payload json.RawMessage) (*dao.Command, error) {
	if !ValidID(id) || !ValidID(workspace) {
		return nil, errors.New("invalid command or workspace ID")
	}
	allowed := map[string]bool{"chat": true, "message": true, "answer": true, "approval": true, "cancel": true, "continue": true, "coworker": true}
	if !allowed[kind] || len(payload) == 0 || len(payload) > 64<<10 || !json.Valid(payload) {
		return nil, errors.New("unsupported command or payload")
	}
	digest := Hash(device + workspace + kind + string(payload))
	var result dao.Command
	err := s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		// Serialize queue/revocation/claim against this device. A token is never a user credential.
		var d dao.Device
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND user_id = ? AND revoked_at IS NULL", device, user).First(&d).Error; err != nil {
			return err
		}
		err := tx.First(&result, "id = ?", id).Error
		if err == nil {
			if result.UserID != user || result.DeviceID != device || result.Digest != digest {
				return ErrConflict
			}
			return nil
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		if time.Since(d.LastSeen) > 45*time.Second {
			return ErrOffline
		}
		var w dao.Workspace
		if err := tx.Where("id = ? AND device_id = ?", workspace, device).First(&w).Error; err != nil {
			return err
		}
		var count int64
		if err := tx.Model(&dao.Command{}).Where("device_id = ? AND status IN ? AND expires_at > ?", device, []string{"queued", "leased"}, time.Now().UTC()).Count(&count).Error; err != nil {
			return err
		}
		if count >= 64 {
			return errors.New("device command queue is full")
		}
		now := time.Now().UTC()
		result = dao.Command{ID: id, UserID: user, DeviceID: device, WorkspaceID: workspace, Kind: kind, Payload: payload, Digest: digest, Status: "queued", CreatedAt: now, ExpiresAt: now.Add(time.Minute)}
		return tx.Create(&result).Error
	})
	return &result, err
}
func (s Relay) Claim(ctx context.Context, device string) ([]dao.Command, error) {
	commands := []dao.Command{}
	err := s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var d dao.Device
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND revoked_at IS NULL", device).First(&d).Error; err != nil {
			return err
		}
		now := time.Now().UTC()
		if err := tx.Model(&d).Update("last_seen", now).Error; err != nil {
			return err
		}
		if err := tx.Model(&dao.Command{}).Where("device_id = ? AND expires_at <= ? AND status IN ?", device, now, []string{"queued", "leased"}).Updates(map[string]any{"status": "expired", "payload": []byte("{}")}).Error; err != nil {
			return err
		}
		if err := pruneCommands(tx, device); err != nil {
			return err
		}
		if err := tx.Where("device_id = ? AND expires_at > ? AND (status = 'queued' OR (status = 'leased' AND lease_until < ?))", device, now, now).Order("created_at,id").Limit(8).Find(&commands).Error; err != nil {
			return err
		}
		until := now.Add(30 * time.Second)
		for i := range commands {
			commands[i].Status = "leased"
			commands[i].LeaseUntil = &until
			if err := tx.Model(&commands[i]).Updates(map[string]any{"status": "leased", "lease_until": until}).Error; err != nil {
				return err
			}
		}
		return nil
	})
	return commands, err
}
func (s Relay) Ack(ctx context.Context, device, id, status, result string) error {
	if !ValidID(id) || (status != "delivered" && status != "failed" && status != "uncertain") || len(result) > 500 {
		return errors.New("invalid acknowledgement")
	}
	return s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var d dao.Device
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND revoked_at IS NULL", device).First(&d).Error; err != nil {
			return err
		}
		var c dao.Command
		if err := tx.Where("id = ? AND device_id = ?", id, device).First(&c).Error; err != nil {
			return err
		}
		if c.Status == status {
			return nil
		}
		if c.Status != "leased" {
			return ErrConflict
		}
		if err := tx.Model(&c).Updates(map[string]any{"status": status, "result": result, "payload": []byte("{}")}).Error; err != nil {
			return err
		}
		return pruneCommands(tx, device)
	})
}

// Apply accepts only bounded set/append/remove operations; it never interprets keys as code.
func Apply(root any, patches []Patch) (any, error) {
	if len(patches) > 4096 {
		return nil, errors.New("too many patch operations")
	}
	for _, p := range patches {
		if len(p.Path) == 0 || len(p.Path) > 32 {
			return nil, errors.New("invalid patch path")
		}
		for _, key := range p.Path {
			if key == "__proto__" || key == "prototype" || key == "constructor" {
				return nil, errors.New("invalid patch key")
			}
		}
		var err error
		root, err = patchAt(root, p.Path, p)
		if err != nil {
			return nil, err
		}
	}
	return root, nil
}
func patchAt(node any, path []string, p Patch) (any, error) {
	if len(path) == 0 {
		switch p.Op {
		case "set":
			return p.Value, nil
		case "append":
			old, ok := node.(string)
			next, ok2 := p.Value.(string)
			if ok && ok2 {
				return old + next, nil
			}
		}
		return nil, errors.New("invalid patch operation")
	}
	key := path[0]
	switch v := node.(type) {
	case map[string]any:
		if len(path) == 1 && p.Op == "remove" {
			delete(v, key)
			return v, nil
		}
		next, err := patchAt(v[key], path[1:], p)
		if err != nil {
			return nil, err
		}
		v[key] = next
		return v, nil
	case []any:
		i, err := strconv.Atoi(key)
		if err != nil || i < 0 || i > len(v) {
			return nil, errors.New("invalid array index")
		}
		if i == len(v) {
			if len(path) != 1 || p.Op != "set" {
				return nil, errors.New("invalid array append")
			}
			return append(v, p.Value), nil
		}
		if len(path) == 1 && p.Op == "remove" {
			return append(v[:i], v[i+1:]...), nil
		}
		next, err := patchAt(v[i], path[1:], p)
		if err != nil {
			return nil, err
		}
		v[i] = next
		return v, nil
	default:
		return nil, errors.New("patch parent is missing")
	}
}
func (s Relay) Upload(ctx context.Context, device string, u Upload) error {
	if !ValidID(u.RunID) || !ValidID(u.WorkspaceID) || !ValidID(u.Generation) || u.Version == 0 {
		return errors.New("invalid snapshot identity")
	}
	if u.Kind != "run_snapshot" && u.Kind != "run_patch" && u.Kind != "run_deleted" {
		return errors.New("invalid event type")
	}
	return s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var d dao.Device
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND revoked_at IS NULL", device).First(&d).Error; err != nil {
			return err
		}
		var w dao.Workspace
		if err := tx.Where("id = ? AND device_id = ?", u.WorkspaceID, device).First(&w).Error; err != nil {
			return err
		}
		if u.Kind == "run_deleted" {
			if err := tx.Where("device_id = ? AND run_id = ?", device, u.RunID).Delete(&dao.Snapshot{}).Error; err != nil {
				return err
			}
			if err := tx.Where("device_id = ? AND run_id = ?", device, u.RunID).Delete(&dao.Event{}).Error; err != nil {
				return err
			}
		} else {
			var old dao.Snapshot
			found := tx.Where("device_id = ? AND run_id = ?", device, u.RunID).First(&old).Error
			if found != nil && !errors.Is(found, gorm.ErrRecordNotFound) {
				return found
			}
			if found == nil && old.Generation == u.Generation && old.Version == u.Version {
				return nil
			}
			var data []byte
			if u.Kind == "run_snapshot" {
				if len(u.Run) == 0 || !json.Valid(u.Run) {
					return errors.New("invalid run snapshot")
				}
				data = u.Run
			} else {
				if found != nil || old.Generation != u.Generation || old.Version != u.BaseVersion || u.Version != u.BaseVersion+1 || old.WorkspaceID != u.WorkspaceID {
					return ErrConflict
				}
				var root any
				if err := json.Unmarshal(old.Data, &root); err != nil {
					return err
				}
				changed, err := Apply(root, u.Changes)
				if err != nil {
					return err
				}
				data, err = json.Marshal(changed)
				if err != nil {
					return err
				}
			}
			if len(data) > 4<<20 {
				return errors.New("snapshot exceeds 4 MiB")
			}
			var obj map[string]any
			if json.Unmarshal(data, &obj) != nil || obj["id"] != u.RunID {
				return errors.New("snapshot run ID does not match")
			}
			u.Summary = preview(obj)
			row := dao.Snapshot{DeviceID: device, RunID: u.RunID, WorkspaceID: u.WorkspaceID, Generation: u.Generation, Version: u.Version, Data: data, Summary: u.Summary, UpdatedAt: time.Now().UTC()}
			if err := tx.Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "device_id"}, {Name: "run_id"}}, DoUpdates: clause.AssignmentColumns([]string{"workspace_id", "generation", "version", "data", "summary", "updated_at"})}).Create(&row).Error; err != nil {
				return err
			}
		}
		encoded, err := json.Marshal(u)
		if err != nil {
			return err
		}
		id := u.RunID
		if err := tx.Create(&dao.Event{DeviceID: device, RunID: &id, Kind: u.Kind, Data: encoded, CreatedAt: time.Now().UTC()}).Error; err != nil {
			return err
		}
		if err := tx.Exec(`DELETE FROM conductor_events WHERE device_id = ? AND (created_at < ? OR id NOT IN (SELECT id FROM conductor_events WHERE device_id = ? ORDER BY id DESC LIMIT 256))`, device, time.Now().Add(-7*24*time.Hour), device).Error; err != nil {
			return err
		}
		if err := tx.Exec(`DELETE FROM conductor_snapshots WHERE device_id = ? AND run_id NOT IN (SELECT run_id FROM conductor_snapshots WHERE device_id = ? ORDER BY updated_at DESC LIMIT 100)`, device, device).Error; err != nil {
			return err
		}
		return pruneCommands(tx, device)
	})
}
func pruneCommands(tx *gorm.DB, device string) error {
	return tx.Exec(`DELETE FROM conductor_commands WHERE device_id = ? AND status NOT IN ('queued','leased') AND (created_at < ? OR id NOT IN (SELECT id FROM conductor_commands WHERE device_id = ? ORDER BY created_at DESC LIMIT 1000))`, device, time.Now().Add(-7*24*time.Hour), device).Error
}
func WireCommand(c dao.Command) map[string]any {
	return map[string]any{"id": c.ID, "workspace_id": c.WorkspaceID, "kind": c.Kind, "payload": json.RawMessage(c.Payload), "status": c.Status, "result": c.Result, "expires_at": c.ExpiresAt}
}
func preview(obj map[string]any) json.RawMessage {
	data := map[string]any{}
	for _, key := range []string{"id", "title", "prompt", "workspace", "status", "created_at", "finished_at", "workflow"} {
		data[key] = obj[key]
	}
	if prompt, ok := data["prompt"].(string); ok {
		runes := []rune(prompt)
		if len(runes) > 100 {
			data["prompt"] = string(runes[:100]) + "…"
		}
	}
	if chat, ok := obj["conversation"].(map[string]any); ok {
		data["conversation"] = map[string]any{"coworkers": chat["coworkers"], "lead_id": chat["lead_id"]}
	}
	encoded, _ := json.Marshal(data)
	return encoded
}
func Envelope(row dao.Snapshot, summary bool) map[string]any {
	data := row.Data
	if summary {
		data = row.Summary
		if len(data) == 0 {
			data, _ = json.Marshal(map[string]any{"id": row.RunID, "title": "Conversation"})
		}
	}
	return map[string]any{"run_id": row.RunID, "workspace_id": row.WorkspaceID, "generation": row.Generation, "version": row.Version, "run": json.RawMessage(data), "summary": summary}
}
func (s Relay) Run(ctx context.Context, device, run string) (map[string]any, error) {
	if !ValidID(run) {
		return nil, gorm.ErrRecordNotFound
	}
	var row dao.Snapshot
	if err := s.DB.WithContext(ctx).Where("device_id = ? AND run_id = ?", device, run).First(&row).Error; err != nil {
		return nil, err
	}
	return Envelope(row, false), nil
}
func (s Relay) Cleanup(ctx context.Context) error {
	now := time.Now().UTC()
	return s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("expires_at <= ?", now).Delete(&dao.Session{}).Error; err != nil {
			return err
		}
		if err := tx.Model(&dao.Command{}).Where("expires_at <= ? AND status IN ?", now, []string{"queued", "leased"}).Updates(map[string]any{"status": "expired", "payload": []byte("{}")}).Error; err != nil {
			return err
		}
		if err := tx.Where("created_at < ?", now.Add(-7*24*time.Hour)).Delete(&dao.Event{}).Error; err != nil {
			return err
		}
		return tx.Where("created_at < ? AND status NOT IN ?", now.Add(-7*24*time.Hour), []string{"queued", "leased"}).Delete(&dao.Command{}).Error
	})
}
func (s Relay) Overview(ctx context.Context, device string, selected ...string) (map[string]any, error) {
	var cursor uint64
	if err := s.DB.WithContext(ctx).Model(&dao.Event{}).Select("COALESCE(MAX(id),0)").Where("device_id = ?", device).Scan(&cursor).Error; err != nil {
		return nil, err
	}
	var spaces []dao.Workspace
	if err := s.DB.WithContext(ctx).Where("device_id = ?", device).Order("label").Find(&spaces).Error; err != nil {
		return nil, err
	}
	var snapshots []dao.Snapshot
	if err := s.DB.WithContext(ctx).Select("device_id,run_id,workspace_id,generation,version,summary,updated_at").Where("device_id = ?", device).Order("updated_at DESC").Find(&snapshots).Error; err != nil {
		return nil, err
	}
	runs := []any{}
	for _, r := range snapshots {
		if len(selected) > 0 && r.RunID == selected[0] {
			full, err := s.Run(ctx, device, r.RunID)
			if err != nil {
				return nil, err
			}
			runs = append(runs, full)
		} else {
			runs = append(runs, Envelope(r, true))
		}
	}
	var commands []dao.Command
	if err := s.DB.WithContext(ctx).Where("device_id = ?", device).Order("created_at DESC").Limit(20).Find(&commands).Error; err != nil {
		return nil, err
	}
	statuses := []any{}
	for _, c := range commands {
		statuses = append(statuses, WireCommand(c))
	}
	var d dao.Device
	if err := s.DB.WithContext(ctx).First(&d, "id = ?", device).Error; err != nil {
		return nil, err
	}
	connections := json.RawMessage(d.Connections)
	if len(connections) == 0 {
		connections = json.RawMessage("[]")
	}
	return map[string]any{"cursor": cursor, "device": d, "workspaces": spaces, "connections": connections, "runs": runs, "commands": statuses}, nil
}
func ErrorStatus(err error) int {
	switch {
	case errors.Is(err, gorm.ErrRecordNotFound):
		return 404
	case errors.Is(err, ErrConflict):
		return 409
	case errors.Is(err, ErrOffline):
		return 503
	default:
		return 400
	}
}
func PublicError(err error) string {
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return "not found"
	}
	if errors.Is(err, ErrConflict) || errors.Is(err, ErrOffline) {
		return err.Error()
	}
	return fmt.Sprint("request could not be completed")
}
