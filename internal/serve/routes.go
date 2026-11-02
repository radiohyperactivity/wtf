package serve

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/radiohyperactivity/wtf/openapi"
)

// route is one API endpoint. The list of routes is also checked against the
// OpenAPI description by a test.
type route struct {
	pattern string // "METHOD /path"
	handler handlerFunc
}

// handlerFunc handles a request; a returned error becomes a problem response.
type handlerFunc func(w http.ResponseWriter, r *http.Request) error

func (s *server) routes() []route {
	limit, after := query("p_limit", "limit", "integer"), query("p_after", "after", "uuid")
	dryRun := flag("p_dry_run", "dry_run")
	class, attribute := path("p_class", "id"), pathText("p_name", "attribute")
	routes := []route{
		{"GET /health", s.health},
		{"GET /openapi", s.openAPI},

		{"POST /model/import", s.update("model.import", patch("p_data"),
			queryOrNull("p_parent", "parent", "uuid"), dryRun)},

		{"GET /classes", s.versioned("class.list", "tree")},
		{"POST /classes", s.create("class.create", "/classes/", body(
			field{key: "name", name: "p_name", typ: "text"},
			field{key: "parent", name: "p_parent", typ: "uuid"},
			field{key: "container", name: "p_container", typ: "boolean"},
		))},
		{"GET /classes/{id}", s.read("class.get", class)},
		{"PATCH /classes/{id}", s.update("class.patch", class, patch("p_patch"))},
		{"DELETE /classes/{id}", s.removeTree("class.delete", "class.delete_tree", class)},
		{"GET /classes/{id}/model", s.read("model.export", class)},
		{"GET /classes/{id}/deletion", s.read("class.delete_tree", class,
			flag("p_force", "force"), constant("p_dry_run", "boolean", true))},
		{"POST /classes/{id}/attributes", s.update("class.attribute_add", class, body(
			field{key: "name", name: "p_name", typ: "text"},
			field{key: "definition", name: "p_definition", typ: "jsonb"},
		), dryRun)},
		{"PATCH /classes/{id}/attributes/{attribute}", s.update("class.attribute_change",
			class, attribute, patch("p_patch"), dryRun)},
		{"DELETE /classes/{id}/attributes/{attribute}", s.update("class.attribute_remove",
			class, attribute, dryRun)},
		{"POST /classes/{id}/attributes/{attribute}/rename", s.update("class.attribute_rename",
			class, attribute, body(field{key: "name", name: "p_new_name", typ: "text"}), dryRun)},
		{"POST /classes/{id}/attributes/{attribute}/choices", s.update("class.choice_add",
			class, attribute, body(field{key: "choice", name: "p_choice", typ: "text"}), dryRun)},
		{"POST /classes/{id}/attributes/{attribute}/choices/{choice}/rename", s.update("class.choice_rename",
			class, attribute, pathText("p_choice", "choice"),
			body(field{key: "choice", name: "p_new_choice", typ: "text"}), dryRun)},
		{"DELETE /classes/{id}/attributes/{attribute}/choices/{choice}", s.update("class.choice_remove",
			class, attribute, pathText("p_choice", "choice"), dryRun)},

		{"GET /items", s.read("item.list",
			query("p_class", "class", "uuid"),
			query("p_search", "search", "text"),
			query("p_where", "where", "jsonb"),
			limit, after)},
		{"POST /items", s.create("item.create", "/items/", body(
			field{key: "class", name: "p_class", typ: "uuid"},
			field{key: "name", name: "p_name", typ: "text"},
			field{key: "unit", name: "p_unit", typ: "text"},
			field{key: "values", name: "p_values", typ: "jsonb"},
		))},
		{"GET /items/{id}", s.read("item.get", path("p_item", "id"))},
		{"PATCH /items/{id}", s.update("item.patch", path("p_item", "id"), patch("p_patch"))},
		{"DELETE /items/{id}", s.remove("item.delete", path("p_item", "id"))},
		{"GET /items/{id}/photo", s.download("item", false)},
		{"GET /items/{id}/files/{attribute}", s.download("item", true)},

		{"GET /locations", s.versioned("location.list", "tree")},
		{"POST /locations", s.create("location.create", "/locations/", locationBody())},
		{"GET /locations/{id}", s.read("location.get", path("p_location", "id"))},
		{"PATCH /locations/{id}", s.update("location.patch", path("p_location", "id"), patch("p_patch"))},
		{"DELETE /locations/{id}", s.removeTree("location.delete", "location.delete_tree", path("p_location", "id"))},
		{"GET /locations/{id}/deletion", s.read("location.delete_tree", path("p_location", "id"),
			flag("p_force", "force"), constant("p_dry_run", "boolean", true))},

		{"GET /stock", s.read("stock.list",
			query("p_item", "item", "uuid"),
			query("p_location", "location", "uuid"),
			query("p_search", "search", "text"),
			limit, after)},
		{"POST /stock", s.create("stock.create", "/stock/", body(
			field{key: "item", name: "p_item", typ: "uuid"},
			field{key: "location", name: "p_location", typ: "uuid"},
			field{key: "amount", name: "p_amount", typ: "numeric"},
			field{key: "reference", name: "p_reference", typ: "text"},
			field{key: "serial", name: "p_serial", typ: "text"},
			field{key: "values", name: "p_values", typ: "jsonb"},
		))},
		{"GET /stock/{id}", s.read("stock.get", path("p_stock", "id"))},
		{"PATCH /stock/{id}", s.update("stock.patch", path("p_stock", "id"), patch("p_patch"))},
		{"DELETE /stock/{id}", s.remove("stock.delete", path("p_stock", "id"))},
		{"POST /stock/{id}/move", s.update("stock.move", path("p_stock", "id"), body(
			field{key: "location", name: "p_location", typ: "uuid"},
			field{key: "amount", name: "p_amount", typ: "numeric"},
		))},
		{"POST /stock/{id}/merge", s.update("stock.merge", path("p_stock", "id"), body(
			field{key: "into", name: "p_into", typ: "uuid"},
			field{key: "amount", name: "p_amount", typ: "numeric"},
			field{key: "resolve", name: "p_resolve", typ: "jsonb"},
		))},
		{"GET /stock/{id}/photo", s.download("stock", false)},
		{"GET /stock/{id}/files/{attribute}", s.download("stock", true)},

		{"POST /login", s.login},
		{"POST /logout", s.logout},
		{"GET /me", s.read("account.me")},
		{"PUT /me/password", s.remove("account.password_change", body(
			field{key: "current", name: "p_current", typ: "text"},
			field{key: "new", name: "p_new", typ: "text"},
			field{key: "end_other_sessions", name: "p_end_other_sessions", typ: "boolean"},
		))},
		{"GET /me/sessions", s.read("account.session_list")},
		{"DELETE /me/sessions/{id}", s.sessionLogout},
		{"POST /me/sessions/logout-others", s.logoutOthers},
		{"GET /accounts", s.read("account.list")},
		{"POST /accounts", s.create("account.create", "/accounts/", body(
			field{key: "email", name: "p_email", typ: "text"},
			field{key: "password", name: "p_password", typ: "text"},
			field{key: "role", name: "p_role", typ: "role"},
		))},
		{"GET /accounts/{id}", s.read("account.get", path("p_account", "id"))},
		{"PATCH /accounts/{id}", s.update("account.patch", path("p_account", "id"), patch("p_patch"))},
		{"DELETE /accounts/{id}", s.remove("account.delete", path("p_account", "id"))},

		{"GET /codes/{code}", s.read("code.resolve", pathText("p_code", "code"))},
	}
	return routes
}

// uploadRoutes are the routes that take a file upload. Their body limit is
// the attachment size instead of the JSON body size.
func (s *server) uploadRoutes() []route {
	return []route{
		{"PUT /items/{id}/photo", s.upload("item", false)},
		{"PUT /items/{id}/files/{attribute}", s.upload("item", true)},
		{"PUT /stock/{id}/photo", s.upload("stock", false)},
		{"PUT /stock/{id}/files/{attribute}", s.upload("stock", true)},
	}
}

// queryOrNull passes the query parameter key, or SQL NULL when it is absent,
// for an accessor argument whose NULL means "none" (a parent: the top).
func queryOrNull(name, key, typ string) param {
	optional := query(name, key, typ)
	return func(r *http.Request) ([]arg, error) {
		args, err := optional(r)
		for i := range args {
			args[i].optional = false
		}
		return args, err
	}
}

// flag passes the query parameter key as a boolean: true or false, and
// false when it is absent, as a flag in a URL is.
func flag(name, key string) param {
	return func(r *http.Request) ([]arg, error) {
		v := r.URL.Query().Get(key)
		switch v {
		case "", "false":
			return []arg{{name: name, typ: "boolean", value: false}}, nil
		case "true":
			return []arg{{name: name, typ: "boolean", value: true}}, nil
		}
		return nil, invalidInput("query parameter %s=%q must be true or false", key, v)
	}
}

// locationBody takes POST /locations' body apart: name, parent and
// container, and grid ({columns, rows, confirm}, or null for none) into
// p_columns, p_rows and p_confirm.
func locationBody() param {
	return func(r *http.Request) ([]arg, error) {
		object, err := readObject(r)
		if err != nil {
			return nil, err
		}
		grid, ok := object["grid"]
		if !ok {
			return nil, invalidInput("field %q is required (it may be null)", "grid")
		}
		delete(object, "grid")
		args, err := fieldArgs(object, []field{
			{key: "name", name: "p_name", typ: "text"},
			{key: "parent", name: "p_parent", typ: "uuid"},
			{key: "container", name: "p_container", typ: "boolean"},
		})
		if err != nil {
			return nil, err
		}
		var cells map[string]json.RawMessage
		if string(grid) != "null" {
			if err := json.Unmarshal(grid, &cells); err != nil || cells == nil {
				return nil, invalidInput(`grid must be {"columns": <number>, "rows": <number>, "confirm": <true or false, optional>}, or null`)
			}
			if _, ok := cells["confirm"]; !ok {
				cells["confirm"] = json.RawMessage("false")
			}
		} else {
			cells = map[string]json.RawMessage{"columns": grid, "rows": grid, "confirm": grid}
		}
		gridArgs, err := fieldArgs(cells, []field{
			{key: "columns", name: "p_columns", typ: "integer"},
			{key: "rows", name: "p_rows", typ: "integer"},
			{key: "confirm", name: "p_confirm", typ: "boolean"},
		})
		if p, ok := err.(*problem); ok {
			// Say which object the field is in.
			p.Detail = "grid: " + p.Detail
		}
		if err != nil {
			return nil, err
		}
		return append(args, gridArgs...), nil
	}
}

// read calls fn and responds 200 with its result.
func (s *server) read(fn string, params ...param) handlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		args, err := collect(r, params)
		if err != nil {
			return err
		}
		result, err := s.callJSON(r.Context(), fn, args)
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, result)
		return nil
	}
}

// update is read for requests that change something (PATCH, PUT, actions).
func (s *server) update(fn string, params ...param) handlerFunc {
	return s.read(fn, params...)
}

// create calls fn and responds 201, with a Location header made of prefix and
// the id of the created object.
func (s *server) create(fn, prefix string, params ...param) handlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		args, err := collect(r, params)
		if err != nil {
			return err
		}
		result, err := s.callJSON(r.Context(), fn, args)
		if err != nil {
			return err
		}
		var created struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(result, &created); err != nil || created.ID == "" {
			return fmt.Errorf("%s: result has no id", fn)
		}
		w.Header().Set("Location", apiPrefix+prefix+created.ID)
		writeJSON(w, http.StatusCreated, result)
		return nil
	}
}

// remove calls a void fn and responds 204.
func (s *server) remove(fn string, params ...param) handlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		args, err := collect(r, params)
		if err != nil {
			return err
		}
		if err := s.callVoid(r.Context(), fn, args); err != nil {
			return err
		}
		w.WriteHeader(http.StatusNoContent)
		return nil
	}
}

// removeTree is remove for a tree node; with ?recursive=true it calls
// treeFn instead, which deletes the node with everything below it (?force)
// and responds 200 with what was deleted. The preview of such a delete is a
// GET (…/deletion), so a server that doesn't know recursive deletes can't
// mistake it for a real one.
func (s *server) removeTree(fn, treeFn string, id param) handlerFunc {
	single := s.remove(fn, id)
	recursive := s.read(treeFn, id, flag("p_force", "force"), constant("p_dry_run", "boolean", false))
	return func(w http.ResponseWriter, r *http.Request) error {
		switch r.URL.Query().Get("recursive") {
		case "", "false":
			return single(w, r)
		case "true":
			return recursive(w, r)
		}
		return invalidInput("query parameter recursive=%q must be true or false", r.URL.Query().Get("recursive"))
	}
}

// versioned serves what clients keep and ask for again by version (the
// class and location trees), with ETag and If-None-Match: the function gets
// the version the client has, and answers {version, unchanged: true} (sent
// as 304) or {version, unchanged: false, nodes}. The answer is {version,
// <key>: <tree>}, the nodes, each with its parent, nested into a tree, each
// node with its children in the database's order.
func (s *server) versioned(fn, key string) handlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		var args []arg
		known := arg{name: "p_known_version", typ: "bigint", optional: true}
		if v, ok := parseETag(r.Header.Get("If-None-Match")); ok {
			known.value = v
		}
		result, err := s.callJSON(r.Context(), fn, append(args, known))
		if err != nil {
			return err
		}
		var answer struct {
			Version   int64             `json:"version"`
			Unchanged bool              `json:"unchanged"`
			Nodes     []json.RawMessage `json:"nodes"`
		}
		if err := json.Unmarshal(result, &answer); err != nil {
			return err
		}

		w.Header().Set("ETag", fmt.Sprintf(`"%d"`, answer.Version))
		w.Header().Set("Cache-Control", "no-cache")
		if answer.Unchanged {
			w.WriteHeader(http.StatusNotModified)
			return nil
		}
		tree, err := s.nest(answer.Nodes)
		if err != nil {
			return err
		}
		out, err := json.Marshal(map[string]any{"version": answer.Version, key: tree})
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, out)
		return nil
	}
}

// nest builds a tree from flat nodes, each with its id and parent, in one
// pass: every node gets children (its child nodes, in the order of the
// list). A node whose parent isn't in the list, which would be a bug, is
// logged and put at the top.
func (s *server) nest(nodes []json.RawMessage) ([]map[string]any, error) {
	type node = map[string]any
	all := make([]node, len(nodes))
	byID := make(map[string]node, len(nodes))
	for i, raw := range nodes {
		var n node
		if err := json.Unmarshal(raw, &n); err != nil {
			return nil, err
		}
		n["children"] = []node{}
		all[i] = n
		if id, ok := n["id"].(string); ok {
			byID[id] = n
		}
	}
	top := []node{}
	for _, n := range all {
		parentID, _ := n["parent"].(string)
		if parentID == "" {
			top = append(top, n)
			continue
		}
		parent, ok := byID[parentID]
		if !ok {
			s.log.Error("a tree node's parent is missing", "node", n["id"], "parent", parentID)
			top = append(top, n)
			continue
		}
		parent["children"] = append(parent["children"].([]node), n)
	}
	return top, nil
}

// parseETag returns the first version number in an If-None-Match header such
// as `"17"`, `W/"17"` or `"16", "17"`.
func parseETag(header string) (int64, bool) {
	for _, tag := range strings.Split(header, ",") {
		tag = strings.TrimPrefix(strings.TrimSpace(tag), "W/")
		if v, err := strconv.ParseInt(strings.Trim(tag, `"`), 10, 64); err == nil {
			return v, true
		}
	}
	return 0, false
}

func (s *server) health(w http.ResponseWriter, r *http.Request) error {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	if err := s.pool.Ping(ctx); err != nil {
		s.log.Warn("health check failed", "error", err)
		writeProblem(w, &problem{
			Type:   "/problems/unavailable",
			Title:  "Database unavailable",
			Status: http.StatusServiceUnavailable,
		})
		return nil
	}
	writeJSON(w, http.StatusOK, []byte(`{"status":"ok"}`))
	return nil
}

// openAPI sends the API's description, openapi/openapi.json. JSON is valid
// YAML, so the same bytes are sent as application/yaml when the client asks
// for YAML rather than JSON.
func (s *server) openAPI(w http.ResponseWriter, r *http.Request) error {
	contentType := "application/json"
	accept := r.Header.Get("Accept")
	if strings.Contains(accept, "yaml") && !strings.Contains(accept, "json") {
		contentType = "application/yaml"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Vary", "Accept")
	_, err := w.Write(openapi.Spec)
	return err
}

func writeJSON(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}
