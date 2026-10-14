package service_test

import (
	"agent-conductor/backend/dao"
	"agent-conductor/backend/internal/testdb"
	"agent-conductor/backend/service"
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestClaimFailsStaleSnippetsRestrictionAndLeasesNextCommand(t *testing.T) {
	db := testdb.Open(t)
	connections, err := json.Marshal([]service.Connection{{Provider: "codex", SnippetsOnly: false}})
	if err != nil {
		t.Fatal(err)
	}
	device := dao.Device{ID: service.ID(), UserID: service.ID(), Name: "Fixture", TokenHash: "fixture-" + service.ID(), LastSeen: time.Now().UTC(), Connections: connections}
	if err := db.Create(&device).Error; err != nil {
		t.Fatal(err)
	}
	expires := time.Now().UTC().Add(time.Minute)
	blocked := dao.Command{ID: service.ID(), UserID: device.UserID, DeviceID: device.ID, WorkspaceID: service.ID(), Kind: "chat", Payload: []byte(`{"workspace_access":{"codex":false}}`), Status: "queued", CreatedAt: time.Now().UTC(), ExpiresAt: expires}
	normal := dao.Command{ID: service.ID(), UserID: device.UserID, DeviceID: device.ID, WorkspaceID: service.ID(), Kind: "cancel", Payload: []byte(`{}`), Status: "queued", CreatedAt: time.Now().UTC().Add(time.Millisecond), ExpiresAt: expires}
	if err := db.Create(&blocked).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&normal).Error; err != nil {
		t.Fatal(err)
	}
	claimed, err := (service.Relay{DB: db}).Claim(context.Background(), device.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(claimed) != 1 || claimed[0].ID != normal.ID {
		t.Fatalf("claimed %#v, want only the unrelated command", claimed)
	}
	var saved dao.Command
	if err := db.First(&saved, "id = ?", blocked.ID).Error; err != nil {
		t.Fatal(err)
	}
	if saved.Status != "failed" {
		t.Fatalf("stale restriction status = %q", saved.Status)
	}
}
