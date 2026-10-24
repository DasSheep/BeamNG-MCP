// BeamMP resource helper. Network work stays outside the plugin Lua states.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const maxBody = 65536

var safeName = regexp.MustCompile(`^[A-Za-z0-9_-]{1,96}$`)

type config struct {
	Listen    string `json:"listen"`
	AllowEval bool   `json:"allowEval"`
}
type registration struct {
	Plugin     string `json:"plugin"`
	Generation string `json:"generation"`
	AllowEval  bool   `json:"allowEval"`
	Lua        string `json:"luaVersion"`
}
type envelope struct {
	ID         string          `json:"id"`
	Generation string          `json:"generation"`
	Method     string          `json:"method"`
	Args       json.RawMessage `json:"args"`
	ExpiresAt  int64           `json:"expiresAt"`
}
type response struct {
	Result json.RawMessage `json:"result"`
	Error  string          `json:"error"`
}
type server struct {
	root, session, token string
	timeout              time.Duration
	slots                chan struct{}
}

func atomicFile(path string, b []byte) error {
	f, err := os.OpenFile(path+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(b)
	closeErr := f.Close()
	if err != nil {
		_ = os.Remove(path + ".tmp")
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	// Rename replaces the file atomically on POSIX; readers must never see a removal gap.
	return os.Rename(path+".tmp", path)
}
func readFile(path string, limit int64) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("not a regular file")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if len(b) > int(limit) {
		return nil, errors.New("file exceeds limit")
	}
	return b, err
}
func randomID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}
func (s *server) target(plugin string) (registration, error) {
	var r registration
	if !safeName.MatchString(plugin) {
		return r, errors.New("invalid plugin name")
	}
	dir := filepath.Join(s.session, "plugins", plugin)
	stat, err := os.Lstat(dir)
	if err != nil || !stat.IsDir() || stat.Mode()&os.ModeSymlink != 0 {
		return r, errors.New("plugin bridge unavailable")
	}
	path := filepath.Join(dir, "registration.json")
	b, err := readFile(path, 4096)
	if err != nil {
		return r, errors.New("plugin bridge unavailable")
	}
	if err = json.Unmarshal(b, &r); err != nil || r.Plugin != plugin || !safeName.MatchString(r.Generation) {
		return r, errors.New("invalid plugin registration")
	}
	stat, err = os.Stat(filepath.Join(dir, "heartbeat"))
	if err != nil || time.Since(stat.ModTime()) > 5*time.Second {
		return r, errors.New("plugin heartbeat expired")
	}
	stat, err = os.Lstat(filepath.Join(dir, r.Generation))
	if err != nil || !stat.IsDir() || stat.Mode()&os.ModeSymlink != 0 {
		return r, errors.New("invalid plugin queue")
	}
	return r, nil
}
func (s *server) plugins() []registration {
	out := []registration{}
	entries, _ := os.ReadDir(filepath.Join(s.session, "plugins"))
	for _, e := range entries {
		if r, err := s.target(e.Name()); err == nil {
			out = append(out, r)
		}
	}
	return out
}

// Reap superseded generations and late responses within this helper's own session.
func (s *server) sweep() {
	for _, reg := range s.plugins() {
		base := filepath.Join(s.session, "plugins", reg.Plugin)
		entries, _ := os.ReadDir(base)
		for _, entry := range entries {
			if !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 || !safeName.MatchString(entry.Name()) {
				continue
			}
			path := filepath.Join(base, entry.Name())
			info, err := entry.Info()
			if err != nil {
				continue
			}
			if entry.Name() != reg.Generation && time.Since(info.ModTime()) > 30*time.Second {
				_ = os.RemoveAll(path)
				continue
			}
			if entry.Name() == reg.Generation {
				files, _ := os.ReadDir(path)
				for _, file := range files {
					info, err := file.Info()
					if err == nil && info.Mode().IsRegular() && strings.HasSuffix(file.Name(), ".response") && time.Since(info.ModTime()) > 30*time.Second {
						_ = os.Remove(filepath.Join(path, file.Name()))
					}
				}
			}
		}
	}
}
func (s *server) call(ctx context.Context, plugin, method string, args json.RawMessage) (json.RawMessage, error) {
	reg, err := s.target(plugin)
	if err != nil {
		return nil, err
	}
	if method == "lua_eval" && !reg.AllowEval {
		return nil, errors.New("lua_eval is disabled for this plugin")
	}
	deadline := time.Now().Add(s.timeout)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	id := randomID()
	base := filepath.Join(s.session, "plugins", plugin, reg.Generation, id)
	b, _ := json.Marshal(envelope{ID: id, Generation: reg.Generation, Method: method, Args: args, ExpiresAt: deadline.UnixMilli()})
	if err = atomicFile(base+".request", b); err != nil {
		return nil, err
	}
	defer func() {
		for _, suffix := range []string{".request", ".running", ".response", ".response.tmp"} {
			_ = os.Remove(base + suffix)
		}
	}()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		if b, err = readFile(base+".response", maxBody); err == nil {
			var reply response
			if err = json.Unmarshal(b, &reply); err != nil {
				return nil, errors.New("invalid plugin reply")
			}
			if reply.Error != "" {
				return nil, errors.New(reply.Error)
			}
			if len(reply.Result) == 0 {
				return nil, errors.New("missing plugin result")
			}
			return reply.Result, nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("plugin reply: %w", err)
		}
		current, why := s.target(plugin)
		if why != nil || current.Generation != reg.Generation {
			return nil, errors.New("plugin reloaded or disconnected; execution may have completed; do not retry mutations automatically")
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			// Rename is the claim boundary: removing a queued request wins against a Lua claim.
			state := "unknown"
			if os.Remove(base+".request") == nil {
				state = "not_started"
			}
			return nil, fmt.Errorf("request expired or cancelled; execution=%s; do not retry mutations automatically", state)
		}
		select {
		case <-ctx.Done():
		case <-ticker.C:
		}
	}
}
func rpcError(id json.RawMessage, code int, msg string) map[string]any {
	if len(id) == 0 {
		id = json.RawMessage(`null`)
	}
	return map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": msg}}
}
func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/mcp" {
		http.NotFound(w, r)
		return
	}
	expected := "Bearer " + s.token
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte(expected)) != 1 {
		w.Header().Set("WWW-Authenticate", "Bearer")
		http.Error(w, "Unauthorized", 401)
		return
	}
	if r.Method != "POST" {
		w.Header().Set("Allow", "POST")
		http.Error(w, "Method not allowed", 405)
		return
	}
	if strings.Split(r.Header.Get("Content-Type"), ";")[0] != "application/json" {
		http.Error(w, "application/json required", 415)
		return
	}
	if origin := r.Header.Get("Origin"); origin != "" {
		http.Error(w, "Browser origins are not accepted", 403)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBody)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Request too large", 413)
		return
	}
	var req struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Method  string          `json:"method"`
		Params  json.RawMessage `json:"params"`
	}
	var reply any
	if !json.Valid(raw) {
		reply = rpcError(nil, -32700, "Parse error")
	} else if len(bytes.TrimSpace(raw)) == 0 || bytes.TrimSpace(raw)[0] != '{' || json.Unmarshal(raw, &req) != nil || req.JSONRPC != "2.0" || req.Method == "" || !validID(req.ID) {
		reply = rpcError(nil, -32600, "Invalid Request")
	} else {
		notification := len(req.ID) == 0
		if notification {
			w.WriteHeader(202)
			return
		}
		result, code, why := s.dispatch(r.Context(), req.Method, req.Params)
		if why != "" {
			reply = rpcError(req.ID, code, why)
		} else {
			reply = map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result}
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(reply)
}
func validID(id json.RawMessage) bool {
	if len(id) == 0 || string(id) == "null" {
		return true
	}
	var v any
	if json.Unmarshal(id, &v) != nil {
		return false
	}
	switch v.(type) {
	case string, float64:
		return true
	}
	return false
}
func (s *server) dispatch(ctx context.Context, method string, params json.RawMessage) (any, int, string) {
	switch method {
	case "initialize":
		return map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]any{"name": "beammcp-beammp", "version": "0.1.0"}, "instructions": "BeamMP server development. Choose a registered plugin explicitly for inspection and evaluation. Vehicle poses are client-reported. Eval is trusted code, not sandboxed. Never automatically retry a mutation after timeout."}, 0, ""
	case "ping":
		return map[string]any{}, 0, ""
	case "tools/list":
		return map[string]any{"tools": toolDefinitions()}, 0, ""
	case "tools/call":
		var p struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if json.Unmarshal(params, &p) != nil || !knownTool(p.Name) {
			return nil, -32602, "unknown tool or invalid params"
		}
		if len(p.Arguments) == 0 {
			p.Arguments = json.RawMessage(`{}`)
		}
		if err := validateArguments(p.Name, p.Arguments); err != nil {
			return nil, -32602, err.Error()
		}
		var args map[string]json.RawMessage
		if json.Unmarshal(p.Arguments, &args) != nil || args == nil {
			return nil, -32602, "arguments must be an object"
		}
		select {
		case s.slots <- struct{}{}:
			defer func() { <-s.slots }()
		default:
			return toolResult(nil, errors.New("eight calls already active")), 0, ""
		}
		if p.Name == "list_plugins" {
			b, _ := json.Marshal(map[string]any{"plugins": s.plugins()})
			return toolResult(b, nil), 0, ""
		}
		plugin := "BeamMCP"
		if v, ok := args["plugin"]; ok {
			if json.Unmarshal(v, &plugin) != nil {
				return nil, -32602, "plugin must be a string"
			}
		}
		if !safeName.MatchString(plugin) {
			return nil, -32602, "invalid plugin name"
		}
		delete(args, "plugin")
		payload, _ := json.Marshal(args)
		if p.Name == "observe_lua" {
			initial, err := s.target(plugin)
			if err != nil {
				return toolResult(nil, err), 0, ""
			}
			fetch := func(c context.Context) (json.RawMessage, error) {
				current, why := s.target(plugin)
				if why != nil {
					return nil, fmt.Errorf("plugin unavailable during observation: %w", why)
				}
				if current.Generation != initial.Generation {
					return nil, errors.New("plugin reloaded during observation")
				}
				var a map[string]json.RawMessage
				_ = json.Unmarshal(payload, &a)
				for _, k := range []string{"duration", "interval", "samples", "condition"} {
					delete(a, k)
				}
				b, _ := json.Marshal(a)
				result, why := s.call(c, plugin, "read_lua", b)
				if why == nil {
					var sample struct {
						Generation string `json:"generation"`
					}
					if err := json.Unmarshal(result, &sample); err != nil {
						return nil, errors.New("invalid read_lua reply during observation")
					}
					if sample.Generation != initial.Generation {
						return nil, errors.New("plugin reloaded during observation")
					}
				}
				return result, why
			}
			result, err := observe(ctx, payload, fetch)
			b, _ := json.Marshal(result)
			return toolResult(b, err), 0, ""
		}
		result, err := s.call(ctx, plugin, p.Name, payload)
		return toolResult(result, err), 0, ""
	default:
		return nil, -32601, "Method not found"
	}
}
func toolResult(b json.RawMessage, err error) any {
	text := string(b)
	if err != nil {
		text = err.Error()
	}
	return map[string]any{"content": []any{map[string]any{"type": "text", "text": text}}, "isError": err != nil}
}

func loadConfig(root string) (config, error) {
	c := config{Listen: "127.0.0.1:23513"}
	b, err := readFile(filepath.Join(root, "config.json"), 4096)
	if err != nil {
		return c, err
	}
	err = json.Unmarshal(b, &c)
	host, _, why := net.SplitHostPort(c.Listen)
	if why != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		return c, errors.New("listen must use a numeric loopback address")
	}
	return c, err
}
func getToken(root string) (string, error) {
	path := filepath.Join(root, "token")
	b, err := readFile(path, 256)
	if err == nil && len(strings.TrimSpace(string(b))) >= 32 {
		if err := os.Chmod(path, 0600); err != nil {
			return "", fmt.Errorf("secure token permissions: %w", err)
		}
		return strings.TrimSpace(string(b)), nil
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	token := randomID() + randomID()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", err
	}
	_, err = f.WriteString(token + "\n")
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	return token, err
}
func stdio(root string) error {
	c, err := loadConfig(root)
	if err != nil {
		return err
	}
	token, err := getToken(root)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 20 * time.Second}
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), maxBody)
	for scanner.Scan() {
		line := append([]byte(nil), scanner.Bytes()...)
		req, err := http.NewRequest("POST", "http://"+c.Listen+"/mcp", bytes.NewReader(line))
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		res, err := client.Do(req)
		if err != nil {
			return err
		}
		body, readErr := io.ReadAll(io.LimitReader(res.Body, 131073))
		_ = res.Body.Close()
		if readErr != nil {
			return readErr
		}
		if res.StatusCode != 200 && res.StatusCode != 202 {
			return fmt.Errorf("MCP HTTP %d", res.StatusCode)
		}
		if len(body) > 131072 {
			return errors.New("response too large")
		}
		if len(bytes.TrimSpace(body)) > 0 {
			fmt.Println(string(bytes.TrimSpace(body)))
		}
	}
	return scanner.Err()
}
func run(root, session string) error {
	if !safeName.MatchString(filepath.Base(session)) || filepath.Dir(session) != filepath.Join(root, ".runtime") {
		return errors.New("invalid session directory")
	}
	defer func() {
		path := filepath.Join(root, ".runtime", "active.json")
		var active struct {
			Session string `json:"session"`
		}
		if b, err := readFile(path, 4096); err == nil && json.Unmarshal(b, &active) == nil && active.Session == filepath.Base(session) {
			_ = os.Remove(path)
		}
		_ = os.RemoveAll(session)
	}()
	c, err := loadConfig(root)
	if err != nil {
		return err
	}
	token, err := getToken(root)
	if err != nil {
		return err
	}
	if err = os.Chmod(filepath.Join(root, ".runtime"), 0700); err != nil {
		return err
	}
	if err = os.Chmod(session, 0700); err != nil {
		return err
	}
	s := &server{root: root, session: session, token: token, timeout: 12 * time.Second, slots: make(chan struct{}, 8)}
	var listener net.Listener
	for i := 0; i < 30; i++ {
		listener, err = net.Listen("tcp", c.Listen)
		if err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: s, ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 18 * time.Second, IdleTimeout: 5 * time.Second, MaxHeaderBytes: 8192}
	done := make(chan struct{})
	defer close(done)
	go func() {
		tick := time.NewTicker(200 * time.Millisecond)
		defer tick.Stop()
		lastSweep := time.Now()
		for {
			select {
			case <-done:
				return
			case <-tick.C:
				beat, e := os.Stat(filepath.Join(session, "heartbeat"))
				_, stop := os.Stat(filepath.Join(session, "stop"))
				if e != nil || time.Since(beat.ModTime()) > 15*time.Second || stop == nil {
					_ = srv.Close()
					return
				}
				_ = atomicFile(filepath.Join(session, "alive"), []byte(fmt.Sprint(time.Now().UnixMilli())))
				if time.Since(lastSweep) > 5*time.Second {
					s.sweep()
					lastSweep = time.Now()
				}
			}
		}
	}()
	if err = atomicFile(filepath.Join(session, "ready.json"), []byte(fmt.Sprintf(`{"pid":%d,"listen":%q}`, os.Getpid(), listener.Addr().String()))); err != nil {
		_ = listener.Close()
		return err
	}
	log.Printf("BeamMCP helper listening on %s", c.Listen)
	err = srv.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
func main() {
	if len(os.Args) < 3 {
		log.Fatal("usage: beammcp-helper serve <resource> <session> | stdio <resource>")
	}
	root, err := filepath.Abs(os.Args[2])
	if err != nil {
		log.Fatal(err)
	}
	switch os.Args[1] {
	case "stdio":
		err = stdio(root)
	case "serve":
		if len(os.Args) != 4 {
			log.Fatal("session required")
		}
		session, why := filepath.Abs(os.Args[3])
		if why != nil {
			log.Fatal(why)
		}
		err = run(root, session)
	default:
		err = errors.New("unknown command")
	}
	if err != nil {
		log.Fatal(err)
	}
}
