package main

import (
	"encoding/json"
	"fmt"
	"math"
)

// Validate the advertised argument contract before a request enters a Lua state.
func validateArguments(name string, raw json.RawMessage) error {
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return err
	}
	for _, def := range toolDefinitions() {
		if def["name"] == name {
			return validateValue(value, def["inputSchema"].(map[string]any), "arguments")
		}
	}
	return fmt.Errorf("unknown tool")
}
func validateValue(v any, schema map[string]any, path string) error {
	if choices, ok := schema["anyOf"].([]any); ok {
		for _, choice := range choices {
			if validateValue(v, choice.(map[string]any), path) == nil {
				return nil
			}
		}
		return fmt.Errorf("%s has an invalid type or value", path)
	}
	if choices, ok := schema["enum"].([]string); ok {
		for _, choice := range choices {
			if v == choice {
				return nil
			}
		}
		return fmt.Errorf("%s has an invalid value", path)
	}
	switch schema["type"] {
	case "object":
		obj, ok := v.(map[string]any)
		if !ok {
			return fmt.Errorf("%s must be an object", path)
		}
		props, _ := schema["properties"].(map[string]any)
		if required, ok := schema["required"].([]string); ok {
			for _, key := range required {
				if _, ok := obj[key]; !ok {
					return fmt.Errorf("%s.%s is required", path, key)
				}
			}
		}
		for key, value := range obj {
			property, known := props[key]
			if !known {
				if schema["additionalProperties"] == false {
					return fmt.Errorf("unknown argument %s.%s", path, key)
				}
				continue
			}
			if err := validateValue(value, property.(map[string]any), path+"."+key); err != nil {
				return err
			}
		}
	case "array":
		arr, ok := v.([]any)
		if !ok {
			return fmt.Errorf("%s must be an array", path)
		}
		if min, ok := schema["minItems"].(int); ok && len(arr) < min {
			return fmt.Errorf("%s has too few items", path)
		}
		if max, ok := schema["maxItems"].(int); ok && len(arr) > max {
			return fmt.Errorf("%s has too many items", path)
		}
		if item, ok := schema["items"].(map[string]any); ok {
			for i, value := range arr {
				if err := validateValue(value, item, fmt.Sprintf("%s[%d]", path, i)); err != nil {
					return err
				}
			}
		}
	case "string":
		if _, ok := v.(string); !ok {
			return fmt.Errorf("%s must be a string", path)
		}
	case "boolean":
		if _, ok := v.(bool); !ok {
			return fmt.Errorf("%s must be boolean", path)
		}
	case "number", "integer":
		n, ok := v.(float64)
		if !ok || schema["type"] == "integer" && n != math.Trunc(n) {
			return fmt.Errorf("%s must be %s", path, schema["type"])
		}
		for key, bound := range schema {
			var b float64
			switch v := bound.(type) {
			case int:
				b = float64(v)
			case float64:
				b = v
			default:
				continue
			}
			if key == "minimum" && n < b || key == "maximum" && n > b {
				return fmt.Errorf("%s is outside its allowed range", path)
			}
		}
	}
	return nil
}
