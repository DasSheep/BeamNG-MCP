package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func copyTree(t *testing.T, from, to string) {
	t.Helper()
	err := filepath.WalkDir(from, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, _ := filepath.Rel(from, path)
		dest := filepath.Join(to, relative)
		if d.IsDir() {
			return os.MkdirAll(dest, 0700)
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(dest, b, 0600)
	})
	if err != nil {
		t.Fatal(err)
	}
}
func TestNativeLuaPluginBridge(t *testing.T) {
	lua, err := exec.LookPath("lua5.3")
	if err != nil {
		t.Skip("lua5.3 required for native bridge integration")
	}
	root := filepath.Join(t.TempDir(), "Resources", "Server", "BeamMCP")
	copyTree(t, "../BeamMCP", root)
	copyTree(t, "../../lua/common/beammcp", filepath.Join(root, "lua", "common", "beammcp"))
	if err = os.WriteFile(filepath.Join(root, "config.json"), []byte(`{"enabled":true,"allowEval":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	session := filepath.Join(root, ".runtime", "testsession")
	if err = os.MkdirAll(session, 0700); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(root, ".runtime", "active.json"), []byte(`{"session":"testsession"}`), 0600)
	worker, _ := filepath.Abs("../../test/beammp_worker.lua")
	codec, _ := filepath.Abs("../../test/vendor/json.lua")
	for _, plugin := range []string{"Example", "Peer"} {
		cmd := exec.Command(lua, worker, root, plugin, codec)
		var output strings.Builder
		cmd.Stdout = &output
		cmd.Stderr = &output
		if err = cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
			if t.Failed() {
				t.Log(output.String())
			}
		})
	}
	s := &server{root: root, session: session, token: "test-secret", timeout: time.Second, slots: make(chan struct{}, 8)}
	for i := 0; i < 100 && len(s.plugins()) < 2; i++ {
		time.Sleep(10 * time.Millisecond)
	}
	if len(s.plugins()) != 2 {
		t.Fatal("bridges did not register")
	}
	call := func(plugin, method, args string) json.RawMessage {
		t.Helper()
		r, e := s.call(context.Background(), plugin, method, json.RawMessage(args))
		if e != nil {
			t.Fatal(e)
		}
		return r
	}
	r := call("Example", "lua_eval", `{"code":"Counter=Counter+1; print('bridge output'); return Counter"}`)
	if !strings.Contains(string(r), `"value":42`) || !strings.Contains(string(r), "bridge output") {
		t.Fatal(string(r))
	}
	if r = call("Peer", "lua_eval", `{"code":"return Counter"}`); !strings.Contains(string(r), `"value":41`) {
		t.Fatal("plugin states leaked", string(r))
	}
	r = call("Example", "read_lua", `{"fields":[{"name":"counter","path":["Counter"]}]}`)
	if !strings.Contains(string(r), `"counter":42`) {
		t.Fatal(string(r))
	}
	r = call("Example", "get_lua_source", `{"path":["FixtureFunction"]}`)
	if !strings.Contains(string(r), "return Counter + 5") {
		t.Fatal(string(r))
	}
	r = call("Example", "lua_eval", `{"code":"BeamMCPBridgeTick(7, 'Counter=999'); return Counter"}`)
	if !strings.Contains(string(r), `"value":42`) {
		t.Fatal("client-shaped tick interpreted payload", string(r))
	}
	observed, _, why := s.dispatch(context.Background(), "tools/call", json.RawMessage(`{"name":"observe_lua","arguments":{"plugin":"Example","fields":[{"name":"count","path":["Counter"]}],"duration":1.2,"interval":0.05}}`))
	if why != "" {
		t.Fatal(why)
	}
	observation := observed.(map[string]any)
	if observation["isError"] == true {
		t.Fatal(observation)
	}
	var sampled struct {
		Count int `json:"count"`
	}
	_ = json.Unmarshal([]byte(observation["content"].([]any)[0].(map[string]any)["text"].(string)), &sampled)
	if sampled.Count < 5 {
		t.Fatal("observation did not span heartbeat refresh", sampled.Count)
	}
	reg, _ := s.target("Example")
	_ = os.WriteFile(filepath.Join(root, "reload-Example"), []byte("1"), 0600)
	for i := 0; i < 100; i++ {
		next, _ := s.target("Example")
		if next.Generation != "" && next.Generation != reg.Generation {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	next, _ := s.target("Example")
	if next.Generation == reg.Generation {
		t.Fatal("reload did not change generation")
	}
	r = call("Example", "lua_eval", `{"code":"return Counter"}`)
	if !strings.Contains(string(r), `"value":42`) {
		t.Fatal("bridge reload changed plugin state", string(r))
	}
	// Reattachment is a mutation: a reply may be invalidated, so never retry it.
	_, _ = s.call(context.Background(), "Example", "lua_eval", json.RawMessage(`{"code":"BeamMCPBridgeInit(); return true"}`))
	for i := 0; i < 100; i++ {
		if _, err := s.target("Example"); err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	r = call("Example", "lua_eval", `{"code":"print('after reattach'); return print == BeamMCPPrintWrapper"}`)
	// Inside eval print is the temporary capture; after it returns the stable wrapper is restored.
	if !strings.Contains(string(r), "after reattach") {
		t.Fatal("print capture broken after reattach", string(r))
	}
	r = call("Example", "lua_eval", `{"code":"BeamMCPPrintWrapper('native bridge log'); return 42"}`)
	if !strings.Contains(string(r), `"value":42`) {
		t.Fatal(string(r))
	}
	r = call("Example", "console_logs", `{"match":"native bridge log"}`)
	if !strings.Contains(string(r), "native bridge log") {
		t.Fatal("print wrapper stopped forwarding after reattach", string(r))
	}
}
