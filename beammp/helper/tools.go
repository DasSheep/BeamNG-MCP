package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

func toolDefinitions() []map[string]any {
	stringProp := map[string]any{"type": "string"}
	path := map[string]any{"type": "array", "maxItems": 24, "items": map[string]any{"anyOf": []any{map[string]any{"type": "string"}, map[string]any{"type": "number"}, map[string]any{"type": "boolean"}, map[string]any{"type": "object", "properties": map[string]any{"via": map[string]any{"enum": []string{"metatable", "index"}}}, "required": []string{"via"}, "additionalProperties": false}}}}
	fields := map[string]any{"type": "array", "minItems": 1, "maxItems": 16, "items": map[string]any{"type": "object", "properties": map[string]any{"name": stringProp, "path": path}, "required": []string{"name", "path"}, "additionalProperties": false}}
	condition := map[string]any{"type": "object", "properties": map[string]any{
		"field": stringProp, "op": map[string]any{"enum": []string{"eq", "ne", "gt", "ge", "lt", "le", "changed", "exists", "missing"}},
		"value": map[string]any{"anyOf": []any{stringProp, map[string]any{"type": "number"}, map[string]any{"type": "boolean"}}},
	}, "required": []string{"field", "op"}, "additionalProperties": false}
	specs := []struct {
		name, description string
		props             map[string]any
		required          []string
		write             bool
	}{
		{"list_plugins", "List currently heartbeating plugin bridges and their reload generations.", nil, nil, false},
		{"runtime_info", "Report actual target Lua/server versions, generation and loaded modules.", nil, nil, false},
		{"get_server_state", "Read server settings and connected-player count.", nil, nil, false},
		{"list_players", "List connected players. Identifiers and IP addresses are omitted.", nil, nil, false},
		{"list_vehicles", "List server vehicle IDs, configurations and client-reported poses; not server physics.", map[string]any{"playerId": map[string]any{"type": "integer", "minimum": 0}, "detail": map[string]any{"type": "boolean"}}, nil, false},
		{"lua_eval", "Execute trusted Lua inside the selected plugin state. Requires allowEval. Output is bounded; execution is not sandboxed.", map[string]any{"code": stringProp}, []string{"plugin", "code"}, true},
		{"inspect_lua", "Browse raw target globals, tables or explicitly exposed debug roots without invoking getters.", map[string]any{"path": path, "filter": stringProp, "kind": stringProp, "offset": map[string]any{"type": "integer", "minimum": 0}, "detail": map[string]any{"type": "boolean"}, "sort": map[string]any{"enum": []string{"key", "type", "value"}}, "searchValues": map[string]any{"type": "boolean"}, "preview": map[string]any{"type": "integer", "minimum": 0, "maximum": 512}}, []string{"plugin"}, false},
		{"get_lua_source", "Read a target Lua function's source using its loaded debug metadata.", map[string]any{"path": path, "offset": map[string]any{"type": "integer", "minimum": 0}}, []string{"plugin", "path"}, false},
		{"read_lua", "Read up to 16 named raw paths in one target state.", map[string]any{"fields": fields, "preview": map[string]any{"type": "integer", "minimum": 0, "maximum": 512}}, []string{"plugin", "fields"}, false},
		{"observe_lua", "Sample target paths over successive plugin ticks; summarize changes and optionally wait for a condition.", map[string]any{"fields": fields, "preview": map[string]any{"type": "integer", "minimum": 0, "maximum": 512}, "duration": map[string]any{"type": "number", "minimum": 0.05, "maximum": 10}, "interval": map[string]any{"type": "number", "minimum": 0.05, "maximum": 2}, "samples": map[string]any{"type": "boolean"}, "condition": condition}, []string{"plugin", "fields"}, false},
		{"console_logs", "Read bounded print output captured in this plugin since its bridge attached. Cursor resets on reload.", map[string]any{"cursor": map[string]any{"type": "integer", "minimum": 0}, "match": stringProp}, nil, false},
		{"recent_events", "Read bounded player/vehicle lifecycle events observed by this bridge. No chat capture.", map[string]any{"cursor": map[string]any{"type": "integer", "minimum": 0}}, nil, false},
	}
	out := []map[string]any{}
	for _, s := range specs {
		props := map[string]any{"plugin": stringProp, "maxBytes": map[string]any{"type": "integer", "minimum": 1024, "maximum": 16384}}
		if s.name == "list_players" || s.name == "list_vehicles" || s.name == "inspect_lua" || s.name == "get_lua_source" || s.name == "console_logs" || s.name == "recent_events" {
			props["limit"] = map[string]any{"type": "integer", "minimum": 1, "maximum": 100}
		}
		for k, v := range s.props {
			props[k] = v
		}
		schema := map[string]any{"type": "object", "properties": props, "additionalProperties": false}
		if len(s.required) > 0 {
			schema["required"] = s.required
		}
		out = append(out, map[string]any{"name": s.name, "description": s.description, "inputSchema": schema, "annotations": map[string]any{"readOnlyHint": !s.write, "destructiveHint": s.write, "openWorldHint": s.write}})
	}
	return out
}
func knownTool(name string) bool {
	for _, d := range toolDefinitions() {
		if d["name"] == name {
			return true
		}
	}
	return false
}

type observationArgs struct {
	Fields []struct {
		Name string `json:"name"`
		Path []any  `json:"path"`
	} `json:"fields"`
	Duration  float64 `json:"duration"`
	Interval  float64 `json:"interval"`
	Samples   bool    `json:"samples"`
	MaxBytes  int     `json:"maxBytes"`
	Condition *struct {
		Field string `json:"field"`
		Op    string `json:"op"`
		Value any    `json:"value"`
	} `json:"condition"`
}

func observe(ctx context.Context, raw json.RawMessage, fetch func(context.Context) (json.RawMessage, error)) (any, error) {
	var a observationArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, err
	}
	var supplied map[string]json.RawMessage
	_ = json.Unmarshal(raw, &supplied)
	if _, ok := supplied["duration"]; !ok {
		a.Duration = 1
	}
	if _, ok := supplied["interval"]; !ok {
		a.Interval = 0.1
	}
	if _, ok := supplied["maxBytes"]; !ok {
		a.MaxBytes = 4096
	}
	if a.Duration < 0.05 || a.Duration > 10 || a.Interval < 0.05 || a.Interval > 2 || a.MaxBytes < 1024 || a.MaxBytes > 16384 || len(a.Fields) < 1 || len(a.Fields) > 16 {
		return nil, errors.New("invalid observation duration, interval, fields or maxBytes")
	}
	names := map[string]bool{}
	for _, f := range a.Fields {
		if f.Name == "" || names[f.Name] {
			return nil, errors.New("fields require unique names")
		}
		names[f.Name] = true
	}
	if a.Condition != nil {
		if !names[a.Condition.Field] {
			return nil, errors.New("condition field must name an observed field")
		}
		switch a.Condition.Op {
		case "eq", "ne", "changed", "exists", "missing":
		case "gt", "ge", "lt", "le":
			if _, ok := a.Condition.Value.(float64); !ok {
				return nil, errors.New("ordered condition requires a number")
			}
		default:
			return nil, errors.New("invalid condition operator")
		}
	}
	start := time.Now()
	ctx, cancel := context.WithTimeout(ctx, time.Duration(a.Duration*float64(time.Second)))
	defer cancel()
	summary := map[string]map[string]any{}
	previous := map[string]string{}
	initial := ""
	samples := []any{}
	count := 0
	sampleBytes := 0
	truncated := false
	status := "complete"
	if a.Condition != nil {
		status = "timeout"
	}
	for {
		b, err := fetch(ctx)
		if err != nil {
			if count > 0 && ctx.Err() != nil {
				break
			}
			return nil, err
		}
		var snap struct {
			Values          map[string]any `json:"values"`
			Unavailable     map[string]any `json:"unavailable"`
			TruncatedFields map[string]any `json:"truncatedFields"`
		}
		if err = json.Unmarshal(b, &snap); err != nil {
			return nil, err
		}
		count++
		for _, f := range a.Fields {
			s := summary[f.Name]
			if s == nil {
				s = map[string]any{"changes": 0, "unavailable": 0}
				summary[f.Name] = s
			}
			v, present := snap.Values[f.Name]
			unavailable := snap.Unavailable[f.Name] != nil || !present
			if unavailable {
				s["unavailable"] = s["unavailable"].(int) + 1
			} else {
				if _, ok := s["first"]; !ok {
					s["first"] = v
				}
				s["last"] = v
				if n, ok := v.(float64); ok {
					if old, ok := s["min"].(float64); !ok || n < old {
						s["min"] = n
					}
					if old, ok := s["max"].(float64); !ok || n > old {
						s["max"] = n
					}
				}
			}
			enc, _ := json.Marshal(map[string]any{"value": v, "unavailable": unavailable})
			if old, ok := previous[f.Name]; ok && old != string(enc) {
				s["changes"] = s["changes"].(int) + 1
			}
			previous[f.Name] = string(enc)
		}
		if a.Samples {
			sample := map[string]any{"elapsed": time.Since(start).Seconds(), "values": snap.Values, "unavailable": snap.Unavailable}
			encoded, _ := json.Marshal(sample)
			if sampleBytes+len(encoded) <= a.MaxBytes/2 && !truncated {
				samples = append(samples, sample)
				sampleBytes += len(encoded)
			} else {
				truncated = true
			}
		}
		if a.Condition != nil {
			c := a.Condition
			v, present := snap.Values[c.Field]
			present = present && snap.Unavailable[c.Field] == nil && snap.TruncatedFields[c.Field] == nil
			value, _ := json.Marshal(v)
			if count == 1 && present {
				initial = string(value)
			}
			matched := false
			switch c.Op {
			case "exists":
				matched = present
			case "missing":
				matched = !present
			case "changed":
				matched = present && initial != "" && string(value) != initial
			case "eq", "ne":
				want, _ := json.Marshal(c.Value)
				matched = present && (string(value) == string(want))
				if c.Op == "ne" {
					matched = present && !matched
				}
			default:
				if n, ok := v.(float64); ok && present {
					want := c.Value.(float64)
					switch c.Op {
					case "gt":
						matched = n > want
					case "ge":
						matched = n >= want
					case "lt":
						matched = n < want
					case "le":
						matched = n <= want
					}
				}
			}
			if matched {
				status = "matched"
				break
			}
		}
		timer := time.NewTimer(time.Duration(a.Interval * float64(time.Second)))
		select {
		case <-ctx.Done():
			timer.Stop()
			goto finished
		case <-timer.C:
		}
	}
finished:
	out := map[string]any{"count": count, "status": status, "elapsed": time.Since(start).Seconds(), "summary": summary}
	if a.Samples {
		out["samples"] = samples
		out["samplesTruncated"] = truncated
	}
	encoded, _ := json.Marshal(out)
	if len(encoded) > a.MaxBytes {
		delete(out, "samples")
		out["samplesTruncated"] = true
		encoded, _ = json.Marshal(out)
	}
	if len(encoded) > a.MaxBytes {
		return nil, fmt.Errorf("observation summary exceeds maxBytes; select fewer fields or increase budget")
	}
	return out, nil
}
