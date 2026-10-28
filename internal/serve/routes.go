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
	id := path("p_id", "id")
	limit, offset := query("p_limit", "limit", "integer"), query("p_offset", "offset", "integer")
	routes := []route{
		{"GET /health", s.health},
		{"GET /openapi.yaml", s.openAPI},

		{"GET /quantities", s.read("quantity_list")},
		{"GET /quantities/{id}", s.read("quantity_get", pathInt("p_id", "id"))},
		{"GET /unit-families", s.read("unit_family_list", query("p_quantity", "quantity", "integer"))},
		{"GET /unit-families/{id}", s.read("unit_family_get", pathInt("p_id", "id"))},
		{"GET /units", s.read("unit_list",
			query("p_quantity", "quantity", "integer"), query("p_family", "family", "integer"))},
		{"GET /units/{id}", s.read("unit_get", pathInt("p_id", "id"))},
		{"POST /units/import", s.update("unit_import", patch("p_data"),
			query("p_dry_run", "dry_run", "boolean"))},

		{"GET /attributes", s.read("attribute_list")},
		{"POST /attributes", s.create("attribute_create", "/attributes/", body(
			field{key: "name", name: "p_name", typ: "text"},
			field{key: "datatype", name: "p_datatype", typ: "datatype"},
			field{key: "unit", name: "p_unit", typ: "integer"},
			field{key: "unit_lock", name: "p_unit_lock", typ: "boolean", optional: true},
		))},
		{"GET /attributes/{id}", s.read("attribute_get", id)},
		{"PATCH /attributes/{id}", s.update("attribute_patch", id, patch("p_patch"))},
		{"DELETE /attributes/{id}", s.remove("attribute_delete", id)},
		{"POST /attributes/{id}/restore", s.update("attribute_restore", id, patch("p_options"))},
		{"GET /attributes/{id}/options", s.read("attribute_option_list", path("p_attribute", "id"))},
		{"POST /attributes/{id}/options", s.create("attribute_option_create", "/options/",
			path("p_attribute", "id"), body(field{key: "name", name: "p_name", typ: "text"}))},
		{"GET /options/{id}", s.read("attribute_option_get", id)},
		{"PATCH /options/{id}", s.update("attribute_option_patch", id, patch("p_patch"))},
		{"DELETE /options/{id}", s.remove("attribute_option_delete", id)},
		{"POST /options/{id}/restore", s.update("attribute_option_restore", id, patch("p_options"))},

		{"GET /classes", s.tree("class_list")},
		{"POST /classes", s.create("class_create", "/classes/", body(
			field{key: "name", name: "p_name", typ: "text"},
			field{key: "parent", name: "p_parent", typ: "uuid"},
			field{key: "container", name: "p_container", typ: "boolean", optional: true},
		))},
		{"GET /classes/{id}", s.read("class_get", id)},
		{"PATCH /classes/{id}", s.update("class_patch", id, patch("p_patch"))},
		{"DELETE /classes/{id}", s.removeTree("class_delete", "class_delete_tree", id)},
		{"POST /classes/{id}/restore", s.update("class_restore", id, patch("p_options"))},
		{"GET /classes/{id}/deletion", s.read("class_delete_tree", id,
			query("p_force", "force", "boolean"), constant("p_dry_run", "boolean", true))},
		{"PUT /classes/{id}/attributes/{attribute}", s.update("class_attribute_set",
			path("p_class", "id"), path("p_attribute", "attribute"),
			body(
				field{key: "default", name: "p_default", typ: "jsonb"},
				field{key: "per_unit", name: "p_per_unit", typ: "boolean", optional: true},
				field{key: "required", name: "p_required", typ: "boolean", optional: true},
			))},
		{"DELETE /classes/{id}/attributes/{attribute}", s.update("class_attribute_remove",
			path("p_class", "id"), path("p_attribute", "attribute"))},

		{"GET /items", s.read("item_list",
			query("p_class", "class", "uuid"),
			query("p_search", "search", "text"),
			query("p_limit", "limit", "integer"),
			query("p_offset", "offset", "integer"),
			query("p_where", "where", "jsonb"))},
		{"POST /items", s.create("item_create", "/items/", body(
			field{key: "class", name: "p_class", typ: "uuid"},
			field{key: "name", name: "p_name", typ: "text"},
			field{key: "unit", name: "p_unit", typ: "integer"},
			field{key: "unit_lock", name: "p_unit_lock", typ: "boolean", optional: true},
			field{key: "values", name: "p_values", typ: "jsonb"},
		))},
		{"GET /items/{id}", s.read("item_get", id)},
		{"PATCH /items/{id}", s.update("item_patch", id, patch("p_patch"))},
		{"DELETE /items/{id}", s.remove("item_delete", id)},
		{"POST /items/{id}/restore", s.update("item_restore", id, patch("p_options"))},
		{"PUT /items/{id}/values/{attribute}", s.update("value_set",
			path("p_item", "id"), path("p_attribute", "attribute"),
			body(field{key: "value", name: "p_value", typ: "jsonb"}))},
		{"DELETE /items/{id}/values/{attribute}", s.update("value_delete",
			path("p_item", "id"), path("p_attribute", "attribute"))},

		{"GET /locations", s.tree("location_list")},
		{"POST /locations", s.create("location_create", "/locations/", body(
			field{key: "name", name: "p_name", typ: "text"},
			field{key: "parent", name: "p_parent", typ: "uuid"},
			field{key: "container", name: "p_container", typ: "boolean", optional: true},
			field{key: "grid", name: "p_grid", typ: "jsonb", optional: true},
		))},
		{"GET /locations/{id}", s.read("location_get", id)},
		{"PATCH /locations/{id}", s.update("location_patch", id, patch("p_patch"))},
		{"DELETE /locations/{id}", s.removeTree("location_delete", "location_delete_tree", id)},
		{"POST /locations/{id}/restore", s.update("location_restore", id, patch("p_options"))},
		{"GET /locations/{id}/deletion", s.read("location_delete_tree", id,
			query("p_force", "force", "boolean"), constant("p_dry_run", "boolean", true))},

		{"GET /stock", s.read("stock_list",
			query("p_item", "item", "uuid"),
			query("p_location", "location", "uuid"),
			query("p_limit", "limit", "integer"),
			query("p_offset", "offset", "integer"))},
		{"POST /stock", s.create("stock_create", "/stock/", body(
			field{key: "item", name: "p_item", typ: "uuid"},
			field{key: "location", name: "p_location", typ: "uuid"},
			field{key: "quantity", name: "p_quantity", typ: "numeric"},
			field{key: "values", name: "p_values", typ: "jsonb"},
		))},
		{"GET /stock/{id}", s.read("stock_get", id)},
		{"PATCH /stock/{id}", s.update("stock_patch", id, patch("p_patch"))},
		{"DELETE /stock/{id}", s.remove("stock_delete", id)},
		{"POST /stock/{id}/restore", s.update("stock_restore", id, patch("p_options"))},
		{"POST /stock/{id}/move", s.update("stock_move", id, body(
			field{key: "location", name: "p_location", typ: "uuid"},
			field{key: "quantity", name: "p_quantity", typ: "numeric"},
		))},

		{"PUT /stock/{id}/values/{attribute}", s.update("stock_value_set",
			path("p_stock", "id"), path("p_attribute", "attribute"),
			body(field{key: "value", name: "p_value", typ: "jsonb"}))},
		{"DELETE /stock/{id}/values/{attribute}", s.update("stock_value_delete",
			path("p_stock", "id"), path("p_attribute", "attribute"))},

		{"POST /login", s.login},
		{"POST /logout", s.logout},
		{"GET /me", s.read("me")},
		{"PUT /me/password", s.remove("password_change", body(
			field{key: "current", name: "p_current", typ: "text"},
			field{key: "new", name: "p_new", typ: "text"},
		))},
		{"GET /accounts", s.read("account_list")},
		{"POST /accounts", s.create("account_create", "/accounts/", body(
			field{key: "email", name: "p_email", typ: "text"},
			field{key: "password", name: "p_password", typ: "text"},
			field{key: "data_privilege", name: "p_data_privilege", typ: "privilege", optional: true},
			field{key: "model_privilege", name: "p_model_privilege", typ: "privilege", optional: true},
			field{key: "account_privilege", name: "p_account_privilege", typ: "privilege", optional: true},
			field{key: "history_privilege", name: "p_history_privilege", typ: "privilege", optional: true},
		))},
		{"GET /accounts/{id}", s.read("account_get", id)},
		{"PATCH /accounts/{id}", s.update("account_patch", id, patch("p_patch"))},
		{"DELETE /accounts/{id}", s.remove("account_delete", id)},

		{"GET /items/{id}/history", s.read("item_history", id, limit, offset)},
		{"GET /stock/{id}/history", s.read("stock_history", id, limit, offset)},
		{"GET /locations/{id}/history", s.read("location_history", id, limit, offset)},
		{"GET /classes/{id}/history", s.read("class_history", id, limit, offset)},
		{"GET /attributes/{id}/history", s.read("attribute_history", id, limit, offset)},
		{"GET /accounts/{id}/history", s.read("account_history", id, limit, offset)},
		{"GET /locations/history", s.read("location_list_history", limit, offset)},
		{"GET /classes/history", s.read("class_list_history", limit, offset)},
		{"GET /attributes/history", s.read("attribute_list_history", limit, offset)},

		{"GET /codes/{code}", s.read("code_resolve", pathText("p_code", "code"))},
	}
	// Attachments, only ever reached through their object.
	for _, k := range attachmentKinds {
		kind := constant("p_kind", "text", k.kind)
		owner, attachment := path("p_owner", "id"), path("p_id", "attachment")
		base := "/" + k.path + "/{id}/attachments/{attachment}"
		routes = append(routes,
			route{"GET " + base, s.read("attachment_get", kind, owner, attachment)},
			route{"PATCH " + base, s.update("attachment_patch", kind, owner, attachment, patch("p_patch"))},
			route{"DELETE " + base, s.remove("attachment_delete", kind, owner, attachment)},
			route{"GET " + base + "/content", s.download(k.kind)},
			route{"POST " + base + "/restore", s.update("attachment_restore", kind, owner, attachment, patch("p_options"))},
		)
	}
	return routes
}

// attachmentKinds are the kinds of object that have attachments, with the
// path of their routes.
var attachmentKinds = []struct{ kind, path string }{
	{"item", "items"},
	{"stock", "stock"},
	{"location", "locations"},
	{"class", "classes"},
}

// uploadRoutes are the routes that take a file upload. Their body limit is
// the attachment size instead of the JSON body size.
func (s *server) uploadRoutes() []route {
	return []route{
		{"POST /items/{id}/attachments", s.upload("item", "items")},
		{"POST /stock/{id}/attachments", s.upload("stock", "stock")},
		{"POST /locations/{id}/attachments", s.upload("location", "locations")},
		{"POST /classes/{id}/attachments", s.upload("class", "classes")},
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
	recursive := s.read(treeFn, id, query("p_force", "force", "boolean"))
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

// tree serves a versioned tree with ETag / If-None-Match.
func (s *server) tree(fn string) handlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		known := arg{name: "p_known_version", typ: "bigint", optional: true}
		if v, ok := parseETag(r.Header.Get("If-None-Match")); ok {
			known.value = v
		}
		result, err := s.callJSON(r.Context(), fn, []arg{known})
		if err != nil {
			return err
		}
		var meta struct {
			Version   int64 `json:"version"`
			Unchanged bool  `json:"unchanged"`
		}
		if err := json.Unmarshal(result, &meta); err != nil {
			return err
		}

		w.Header().Set("ETag", fmt.Sprintf(`"%d"`, meta.Version))
		w.Header().Set("Cache-Control", "no-cache")
		if meta.Unchanged {
			w.WriteHeader(http.StatusNotModified)
			return nil
		}
		writeJSON(w, http.StatusOK, result)
		return nil
	}
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

func (s *server) openAPI(w http.ResponseWriter, r *http.Request) error {
	w.Header().Set("Content-Type", "application/yaml")
	_, err := w.Write(openapi.Spec)
	return err
}

func writeJSON(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}
