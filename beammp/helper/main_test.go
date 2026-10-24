package main

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T) *server {
	t.Helper()
	root := t.TempDir()
	s := &server{root: root, session: root, token: "test-secret", timeout: time.Second, slots: make(chan struct{}, 8)}
	register(t, s, "Example", "generation1")
	return s
}
func register(t *testing.T, s *server, plugin, generation string) string {
	t.Helper()
	dir := filepath.Join(s.session, "plugins", plugin)
	if err := os.MkdirAll(filepath.Join(dir, generation), 0700); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(registration{Plugin: plugin, Generation: generation, AllowEval: true})
	if err := os.WriteFile(filepath.Join(dir, "registration.json"), b, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "heartbeat"), []byte("1"), 0600); err != nil {
		t.Fatal(err)
	}
	return filepath.Join(dir, generation)
}
func request(s *server, body, auth string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "http://localhost/mcp", strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Authorization", auth)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}
func TestAuthBeforeParsing(t *testing.T) {
	s := fixture(t)
	if w := request(s, "invalid", "Bearer wrong"); w.Code != 401 {
		t.Fatal(w.Code)
	}
	w := request(s, "invalid", "Bearer test-secret")
	if !strings.Contains(w.Body.String(), `"code":-32700`) || !strings.Contains(w.Body.String(), `"id":null`) {
		t.Fatal(w.Body.String())
	}
}
func TestProtocolEnvelopes(t *testing.T) {
	s := fixture(t)
	for _, body := range []string{`[]`, `{"jsonrpc":"1.0","id":1,"method":"ping"}`, `{"jsonrpc":"2.0","id":{},"method":"ping"}`} {
		if w := request(s, body, "Bearer test-secret"); !strings.Contains(w.Body.String(), `"code":-32600`) {
			t.Fatal(w.Body.String())
		}
	}
	if w := request(s, `{"jsonrpc":"2.0","method":"notifications/initialized"}`, "Bearer test-secret"); w.Code != 202 || w.Body.Len() != 0 {
		t.Fatal(w.Code, w.Body.String())
	}
	w := request(s, `{"jsonrpc":"2.0","id":"abc","method":"tools/list"}`, "Bearer test-secret")
	if !strings.Contains(w.Body.String(), `"tools":[`) || !strings.Contains(w.Body.String(), `"name":"lua_eval"`) {
		t.Fatal(w.Body.String())
	}
	if w = request(s, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"missing"}}`, "Bearer test-secret"); !strings.Contains(w.Body.String(), `"code":-32602`) {
		t.Fatal(w.Body.String())
	}
}
func TestQueueRoundTrip(t *testing.T) {
	s := fixture(t)
	dir := filepath.Join(s.session, "plugins", "Example", "generation1")
	done := make(chan error, 1)
	go func() {
		for i := 0; i < 100; i++ {
			files, _ := filepath.Glob(filepath.Join(dir, "*.request"))
			if len(files) > 0 {
				path := files[0]
				raw, _ := os.ReadFile(path)
				var e envelope
				_ = json.Unmarshal(raw, &e)
				if e.Method != "read_lua" || e.Generation != "generation1" {
					done <- os.ErrInvalid
					return
				}
				_ = os.Rename(path, strings.TrimSuffix(path, ".request")+".running")
				done <- atomicFile(strings.TrimSuffix(path, ".request")+".response", []byte(`{"result":{"values":{"count":42}}}`))
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
		done <- os.ErrDeadlineExceeded
	}()
	result, err := s.call(context.Background(), "Example", "read_lua", json.RawMessage(`{"fields":[{"name":"count","path":["count"]}]}`))
	if err != nil || !strings.Contains(string(result), `42`) {
		t.Fatal(string(result), err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	files, _ := os.ReadDir(dir)
	if len(files) != 0 {
		t.Fatal("request files leaked", files)
	}
}
func TestTimeoutCancelsQueuedWork(t *testing.T) {
	s := fixture(t)
	s.timeout = 30 * time.Millisecond
	_, err := s.call(context.Background(), "Example", "lua_eval", json.RawMessage(`{"code":"return 1"}`))
	if err == nil || !strings.Contains(err.Error(), "not_started") {
		t.Fatal(err)
	}
	files, _ := os.ReadDir(filepath.Join(s.session, "plugins", "Example", "generation1"))
	if len(files) != 0 {
		t.Fatal(files)
	}
}
func TestReloadInvalidatesPendingRequest(t *testing.T) {
	s := fixture(t)
	go func() { time.Sleep(20 * time.Millisecond); register(t, s, "Example", "generation2") }()
	_, err := s.call(context.Background(), "Example", "read_lua", json.RawMessage(`{}`))
	if err == nil || !strings.Contains(err.Error(), "reloaded") {
		t.Fatal(err)
	}
}
func TestTargetBoundaries(t *testing.T) {
	s := fixture(t)
	for _, plugin := range []string{"../Example", "", "unknown", "Example/other"} {
		if _, err := s.call(context.Background(), plugin, "runtime_info", json.RawMessage(`{}`)); err == nil {
			t.Fatal(plugin)
		}
	}
	if err := os.Symlink(filepath.Join(s.session, "plugins", "Example"), filepath.Join(s.session, "plugins", "Link")); err != nil {
		t.Skip(err)
	}
	if _, err := s.target("Link"); err == nil {
		t.Fatal("followed target symlink")
	}
}
func TestObservationSamplesAcrossTicks(t *testing.T) {
	count := 0
	fetch := func(context.Context) (json.RawMessage, error) {
		count++
		return json.Marshal(map[string]any{"values": map[string]any{"n": count}})
	}
	r, err := observe(context.Background(), json.RawMessage(`{"fields":[{"name":"n","path":["n"]}],"duration":0.12,"interval":0.05,"samples":true}`), fetch)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(r)
	if count < 2 || !strings.Contains(string(raw), `"changes":`) {
		t.Fatal(count, string(raw))
	}
}

func TestToolArgumentsRejectMalformedRequestsBeforeQueueing(t *testing.T) {
	s := fixture(t)
	for _, args := range []string{`{}`, `{"plugin":"Example","code":null}`, `{"plugin":"Example","code":7}`, `{"plugin":"Example","code":"return 1","maxBytes":12}`, `{"plugin":"Example","code":"return 1","unexpected":true}`} {
		body := `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"lua_eval","arguments":` + args + `}}`
		if w := request(s, body, "Bearer test-secret"); !strings.Contains(w.Body.String(), `"code":-32602`) {
			t.Fatal(w.Body.String())
		}
	}
	files, _ := os.ReadDir(filepath.Join(s.session, "plugins", "Example", "generation1"))
	if len(files) != 0 {
		t.Fatal("invalid input entered plugin queue")
	}
}

func TestRunningTimeoutDoesNotPromiseCancellation(t *testing.T) {
	s := fixture(t)
	s.timeout = 40 * time.Millisecond
	dir := filepath.Join(s.session, "plugins", "Example", "generation1")
	claimed := make(chan struct{})
	go func() {
		for i := 0; i < 100; i++ {
			files, _ := filepath.Glob(filepath.Join(dir, "*.request"))
			if len(files) > 0 {
				_ = os.Rename(files[0], strings.TrimSuffix(files[0], ".request")+".running")
				close(claimed)
				return
			}
			time.Sleep(time.Millisecond)
		}
	}()
	_, err := s.call(context.Background(), "Example", "lua_eval", json.RawMessage(`{"code":"return 1"}`))
	if err == nil || !strings.Contains(err.Error(), "execution=unknown") {
		t.Fatal(err)
	}
	select {
	case <-claimed:
	case <-time.After(time.Second):
		t.Fatal("worker never claimed request")
	}
	files, _ := os.ReadDir(dir)
	if len(files) != 0 {
		t.Fatal("timeout artifacts leaked", files)
	}
}

func TestHelperShutdownOwnsOnlyItsSession(t *testing.T) {
	root := t.TempDir()
	session := filepath.Join(root, ".runtime", "ownsession")
	if err := os.MkdirAll(session, 0700); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(root, "config.json"), []byte(`{"listen":"127.0.0.1:0"}`), 0600)
	_ = os.WriteFile(filepath.Join(session, "heartbeat"), []byte("1"), 0600)
	_ = os.WriteFile(filepath.Join(root, ".runtime", "active.json"), []byte(`{"session":"ownsession"}`), 0600)
	done := make(chan error, 1)
	go func() { done <- run(root, session) }()
	for i := 0; i < 200; i++ {
		if _, err := os.Stat(filepath.Join(session, "ready.json")); err == nil {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, err := os.Stat(filepath.Join(session, "ready.json")); err != nil {
		t.Fatal("helper not ready", err)
	}
	_ = atomicFile(filepath.Join(root, ".runtime", "active.json"), []byte(`{"session":"newsession"}`))
	_ = os.WriteFile(filepath.Join(session, "stop"), []byte("1"), 0600)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("helper failed to stop")
	}
	if _, err := os.Stat(session); !os.IsNotExist(err) {
		t.Fatal("session not removed", err)
	}
	b, err := os.ReadFile(filepath.Join(root, ".runtime", "active.json"))
	if err != nil || !strings.Contains(string(b), "newsession") {
		t.Fatal("removed new session pointer", err)
	}
}

func TestSweepRemovesOnlySupersededOrExpiredArtifacts(t *testing.T) {
	s := fixture(t)
	base := filepath.Join(s.session, "plugins", "Example")
	old := filepath.Join(base, "oldgeneration")
	_ = os.Mkdir(old, 0700)
	then := time.Now().Add(-time.Minute)
	_ = os.Chtimes(old, then, then)
	live := filepath.Join(base, "generation1")
	response := filepath.Join(live, "old.response")
	_ = os.WriteFile(response, []byte("{}"), 0600)
	_ = os.Chtimes(response, then, then)
	_ = os.WriteFile(filepath.Join(live, "active.running"), []byte("{}"), 0600)
	s.sweep()
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatal("old generation retained")
	}
	if _, err := os.Stat(response); !os.IsNotExist(err) {
		t.Fatal("old response retained")
	}
	if _, err := os.Stat(filepath.Join(live, "active.running")); err != nil {
		t.Fatal("removed active request")
	}
}

func TestAtomicRefreshNeverDisappearsFromReaders(t *testing.T) {
	path := filepath.Join(t.TempDir(), "registration.json")
	if err := atomicFile(path, []byte(`{"generation":"one"}`)); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		for i := 0; i < 1000; i++ {
			if err := atomicFile(path, []byte(`{"generation":"one"}`)); err != nil {
				done <- err
				return
			}
		}
		done <- nil
	}()
	var readErr error
	for i := 0; i < 5000; i++ {
		if _, err := readFile(path, 4096); err != nil {
			readErr = err
			break
		}
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if readErr != nil {
		t.Fatal("atomic refresh disappeared from reader", readErr)
	}
}

func TestFailedHelperStartCleansItsSession(t *testing.T) {
	root := t.TempDir()
	session := filepath.Join(root, ".runtime", "failedsession")
	_ = os.MkdirAll(session, 0700)
	_ = os.WriteFile(filepath.Join(root, "config.json"), []byte(`{"listen":"0.0.0.0:23513"}`), 0600)
	_ = os.WriteFile(filepath.Join(root, ".runtime", "active.json"), []byte(`{"session":"failedsession"}`), 0600)
	if err := run(root, session); err == nil {
		t.Fatal("accepted non-loopback bind")
	}
	if _, err := os.Stat(session); !os.IsNotExist(err) {
		t.Fatal("failed-start session leaked")
	}
	if _, err := os.Stat(filepath.Join(root, ".runtime", "active.json")); !os.IsNotExist(err) {
		t.Fatal("failed-start pointer leaked")
	}
}

func TestExistingTokenRegainsOwnerOnlyPermissions(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix file permission contract")
	}
	root := t.TempDir()
	path := filepath.Join(root, "token")
	token := strings.Repeat("a", 64)
	if err := os.WriteFile(path, []byte(token+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0770); err != nil {
		t.Fatal(err)
	}
	actual, err := getToken(root)
	if err != nil || actual != token {
		t.Fatal("existing token changed", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("token permissions are %04o, want 0600", info.Mode().Perm())
	}
}
