package service

import (
	"encoding/json"
	"testing"
)

func TestAppendPatchAndInvalidPaths(t *testing.T) {
	var root any
	_ = json.Unmarshal([]byte(`{"messages":[{"text":"hello"}]}`), &root)
	updated, err := Apply(root, []Patch{{Op: "append", Path: []string{"messages", "0", "text"}, Value: " 🦀"}, {Op: "set", Path: []string{"messages", "1"}, Value: map[string]any{"text": "second"}}})
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(updated)
	if string(encoded) != `{"messages":[{"text":"hello 🦀"},{"text":"second"}]}` {
		t.Fatal(string(encoded))
	}
	for _, patch := range []Patch{{Op: "append", Path: []string{"messages", "0"}, Value: "bad"}, {Op: "set", Path: []string{"messages", "999"}, Value: "bad"}, {Op: "set", Path: []string{"missing", "child"}, Value: true}, {Op: "set", Path: []string{"__proto__", "polluted"}, Value: true}} {
		if _, err := Apply(root, []Patch{patch}); err == nil {
			t.Fatal("invalid patch accepted")
		}
	}
}
