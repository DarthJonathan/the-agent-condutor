package service

import (
	"encoding/json"
	"testing"
)

func TestSnippetsAccessRequiresAdvertisedCapability(t *testing.T) {
	connections, err := json.Marshal([]Connection{{Provider: "codex", SnippetsOnly: true}, {Provider: "kiro", SnippetsOnly: false}})
	if err != nil {
		t.Fatal(err)
	}
	if err := snippetsAccessAllowed(connections, "chat", json.RawMessage(`{"workspace_access":{"codex":false}}`)); err != nil {
		t.Fatal(err)
	}
	if err := snippetsAccessAllowed(connections, "chat", json.RawMessage(`{"workspace_access":{"kiro":false}}`)); err == nil {
		t.Fatal("expected unsupported snippets-only chat to be rejected")
	}
	if err := snippetsAccessAllowed(connections, "coworker", json.RawMessage(`{"provider":"kiro","can_read_workspace":false}`)); err == nil {
		t.Fatal("expected unsupported coworker access change to be rejected")
	}
	if err := snippetsAccessAllowed(connections, "coworker", json.RawMessage(`{"provider":"kiro","can_read_workspace":true}`)); err != nil {
		t.Fatal(err)
	}
}
