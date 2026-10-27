package serve

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
)

// arg is one argument of a database function call. Arguments are passed in
// named notation (p_id => $1::uuid), so their order doesn't matter.
type arg struct {
	name     string // parameter name, e.g. "p_id"
	typ      string // SQL type the value is cast to, e.g. "uuid"
	value    any    // nil means SQL NULL
	optional bool   // when value is nil, leave the argument out so the function's default applies
}

// callSQL builds "SELECT fn(p_a => $1::type, …)" and its argument values.
func callSQL(fn string, args []arg) (string, []any) {
	var parts []string
	var values []any
	for _, a := range args {
		if a.optional && a.value == nil {
			continue
		}
		values = append(values, a.value)
		parts = append(parts, fmt.Sprintf("%s => $%d::%s", a.name, len(values), a.typ))
	}
	return fmt.Sprintf("SELECT %s(%s)", fn, strings.Join(parts, ", ")), values
}

// callJSON calls a function that returns jsonb and returns the JSON text.
func (s *server) callJSON(ctx context.Context, fn string, args []arg) ([]byte, error) {
	sql, values := callSQL(fn, args)
	var out *string
	if err := s.inSession(ctx, func(q querier) error {
		return q.QueryRow(ctx, sql+"::text", values...).Scan(&out)
	}); err != nil {
		return nil, err
	}
	if out == nil {
		return nil, fmt.Errorf("%s returned NULL", fn)
	}
	return []byte(*out), nil
}

// callVoid calls a function that returns void.
func (s *server) callVoid(ctx context.Context, fn string, args []arg) error {
	sql, values := callSQL(fn, args)
	return s.inSession(ctx, func(q querier) error {
		_, err := q.Exec(ctx, sql, values...)
		return err
	})
}

// param extracts function arguments from a request.
type param func(r *http.Request) ([]arg, error)

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// path passes the path segment {key} as a uuid argument.
func path(name, key string) param {
	return func(r *http.Request) ([]arg, error) {
		v := r.PathValue(key)
		if !uuidPattern.MatchString(v) {
			return nil, invalidInput("%q in the path is not a UUID", v)
		}
		return []arg{{name: name, typ: "uuid", value: v}}, nil
	}
}

// pathInt passes the path segment {key} as an integer argument: the ids of
// quantities, unit families and units.
func pathInt(name, key string) param {
	return func(r *http.Request) ([]arg, error) {
		v := r.PathValue(key)
		if _, err := strconv.ParseInt(v, 10, 32); err != nil {
			return nil, invalidInput("%q in the path is not a whole number", v)
		}
		return []arg{{name: name, typ: "integer", value: v}}, nil
	}
}

// pathText passes the path segment {key} as a text argument.
func pathText(name, key string) param {
	return func(r *http.Request) ([]arg, error) {
		return []arg{{name: name, typ: "text", value: r.PathValue(key)}}, nil
	}
}

// query passes the optional query parameter key. typ is "uuid", "text",
// "integer" or "boolean"; all but text are validated here for clearer errors.
func query(name, key, typ string) param {
	return func(r *http.Request) ([]arg, error) {
		if !r.URL.Query().Has(key) {
			return []arg{{name: name, typ: typ, optional: true}}, nil
		}
		v := r.URL.Query().Get(key)
		switch typ {
		case "uuid":
			if !uuidPattern.MatchString(v) {
				return nil, invalidInput("query parameter %s=%q is not a UUID", key, v)
			}
		case "integer":
			if _, err := strconv.Atoi(v); err != nil {
				return nil, invalidInput("query parameter %s=%q is not a whole number", key, v)
			}
		case "boolean":
			if v != "true" && v != "false" {
				return nil, invalidInput("query parameter %s=%q must be true or false", key, v)
			}
		}
		return []arg{{name: name, typ: typ, value: v, optional: true}}, nil
	}
}

// constant passes a fixed argument.
func constant(name, typ string, value any) param {
	return func(*http.Request) ([]arg, error) {
		return []arg{{name: name, typ: typ, value: value}}, nil
	}
}

// field maps a key of the JSON request body to a function argument.
// typ is the SQL type: "uuid", "text" and "datatype" take a JSON string,
// "numeric" a JSON number, "integer" a whole one, "boolean" true or false, and "jsonb" any JSON
// value. A missing key or JSON null is passed as SQL NULL, or, for an
// optional field, left out so the function's default applies.
type field struct {
	key, name, typ string
	optional       bool
}

// body passes fields of the JSON request body. Unknown keys are rejected.
func body(fields ...field) param {
	return func(r *http.Request) ([]arg, error) {
		object, err := readObject(r)
		if err != nil {
			return nil, err
		}

		known := map[string]bool{}
		var args []arg
		for _, f := range fields {
			known[f.key] = true
			raw, ok := object[f.key]
			if !ok || string(raw) == "null" {
				args = append(args, arg{name: f.name, typ: f.typ, optional: f.optional})
				continue
			}
			value, err := fieldValue(f, raw)
			if err != nil {
				return nil, err
			}
			args = append(args, arg{name: f.name, typ: f.typ, value: value})
		}
		for key := range object {
			if !known[key] {
				return nil, invalidInput("unknown field %q", key)
			}
		}
		return args, nil
	}
}

func fieldValue(f field, raw json.RawMessage) (any, error) {
	switch f.typ {
	case "jsonb":
		return string(raw), nil
	case "numeric":
		if raw[0] != '-' && (raw[0] < '0' || raw[0] > '9') {
			return nil, invalidInput("field %q must be a number", f.key)
		}
		return string(raw), nil
	case "integer":
		var n int32
		if err := json.Unmarshal(raw, &n); err != nil {
			return nil, invalidInput("field %q must be a whole number", f.key)
		}
		return n, nil
	case "boolean":
		var b bool
		if err := json.Unmarshal(raw, &b); err != nil {
			return nil, invalidInput("field %q must be true or false", f.key)
		}
		return b, nil
	default:
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return nil, invalidInput("field %q must be a string", f.key)
		}
		return s, nil
	}
}

// patch passes the whole JSON request body as a jsonb argument.
func patch(name string) param {
	return func(r *http.Request) ([]arg, error) {
		object, err := readObject(r)
		if err != nil {
			return nil, err
		}
		text, _ := json.Marshal(object)
		return []arg{{name: name, typ: "jsonb", value: string(text)}}, nil
	}
}

// readObject reads the request body as a JSON object. An empty body counts as
// an empty object.
func readObject(r *http.Request) (map[string]json.RawMessage, error) {
	data, err := io.ReadAll(r.Body)
	if err != nil {
		return nil, err // includes *http.MaxBytesError
	}
	if len(bytes.TrimSpace(data)) == 0 {
		return map[string]json.RawMessage{}, nil
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(data, &object); err != nil || object == nil {
		return nil, invalidInput("the request body must be a JSON object")
	}
	return object, nil
}

// collect runs the params of a route.
func collect(r *http.Request, params []param) ([]arg, error) {
	var args []arg
	for _, p := range params {
		a, err := p(r)
		if err != nil {
			return nil, err
		}
		args = append(args, a...)
	}
	return args, nil
}
