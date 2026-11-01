package integration

// Tests of the functions the API calls (the accessors, db/repeatable/), on
// the database alone: each is called as the API's role does, with a
// request (token, host, address) as its first argument. Plus checks that
// hold for every function, read from the catalogue.

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// caller makes calls as one session of one tenant.
type caller struct {
	d       *testDatabase
	token   string // "" for none
	host    string
	address string
}

// call calls function fn with the request first and args after it, as the
// API role, and returns its JSON answer decoded (nil for none).
func (c caller) call(t *testing.T, fn string, args ...any) (any, error) {
	t.Helper()
	var sql strings.Builder
	fmt.Fprintf(&sql, "SELECT %s(ROW($1::text, $2::text, $3::inet)::public.request", fn)
	for i := range args {
		fmt.Fprintf(&sql, ", $%d", i+4)
	}
	sql.WriteString(")::text")
	params := append([]any{orNull(c.token), c.host, orNull(c.address)}, args...)
	var text *string
	if err := c.d.api.QueryRow(context.Background(), sql.String(), params...).Scan(&text); err != nil {
		return nil, err
	}
	if text == nil || *text == "" {
		return nil, nil
	}
	var v any
	if err := json.Unmarshal([]byte(*text), &v); err != nil {
		t.Fatalf("%s: answer is not JSON: %s", fn, *text)
	}
	return v, nil
}

// must calls fn and fails the test on an error.
func (c caller) must(t *testing.T, fn string, args ...any) any {
	t.Helper()
	v, err := c.call(t, fn, args...)
	if err != nil {
		t.Fatalf("%s: %v", fn, err)
	}
	return v
}

// id calls fn and returns the id in its answer.
func (c caller) id(t *testing.T, fn string, args ...any) string {
	t.Helper()
	return str(t, c.must(t, fn, args...), "id")
}

// accessorTenant is a tenant of its own, with an admin, a user and a viewer
// logged in.
type accessorTenant struct {
	id                  string
	admin, user, viewer caller
	adminAccount        string
}

// newAccessorTenant makes a tenant with host host and its three accounts,
// with passwords hashed at a low bcrypt cost so that tests stay quick, and
// logs each in through account.login.
func newAccessorTenant(t *testing.T, host string) accessorTenant {
	t.Helper()
	d := database(t)
	tenant := d.newTenant(t, host)
	at := accessorTenant{id: tenant}
	for _, role := range []string{"admin", "user", "viewer"} {
		email := role + "@" + host + ".example"
		account := d.id(t, `
			INSERT INTO public.account (tenant, email, password_hash, role)
			VALUES ($1, $2, extensions.crypt('password', extensions.gen_salt('bf', 4)), $3)
			RETURNING id`, tenant, email, role)
		c := caller{d: d, host: host, address: "192.0.2.1"}
		answer := c.must(t, "account.login", email, "password", "test", nil)
		if get(t, answer, "ok") != true {
			t.Fatalf("login %s: %v", email, answer)
		}
		c.token = str(t, answer, "token")
		switch role {
		case "admin":
			at.admin, at.adminAccount = c, account
		case "user":
			at.user = c
		default:
			at.viewer = c
		}
	}
	return at
}

// ---------------------------------------------------------------------------
// Checks that hold for every function
// ---------------------------------------------------------------------------

func TestFunctionCatalogue(t *testing.T) {
	d := database(t)
	ctx := context.Background()
	strings_ := func(sql string, args ...any) []string {
		rows, _ := d.dba.Query(ctx, sql, args...)
		list, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			t.Fatal(err)
		}
		return list
	}
	const ours = `
		FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
		WHERE p.proowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
		  AND n.nspname NOT IN ('extensions', 'wtfd')`

	t.Run("no dynamic SQL", func(t *testing.T) {
		if bad := strings_(`SELECT p.oid::regprocedure::text` + ours + `
			AND p.prosrc ~* '\mEXECUTE\M'`); len(bad) > 0 {
			t.Errorf("functions with EXECUTE: %v", bad)
		}
	})

	// JIT is off in each: compiling these queries takes far longer than
	// running them (seconds against milliseconds), and the planner's
	// estimates of the functions they call are high enough to trigger it.
	t.Run("the API's functions are SECURITY DEFINER with a fixed search path and no JIT", func(t *testing.T) {
		if bad := strings_(`SELECT p.oid::regprocedure::text` + ours + `
			AND p.prosecdef
			AND p.proconfig IS DISTINCT FROM ARRAY['search_path=pg_catalog, pg_temp', 'jit=off']`); len(bad) > 0 {
			t.Errorf("without search_path = pg_catalog, pg_temp and jit = off: %v", bad)
		}
		if bad := strings_(`SELECT p.oid::regprocedure::text` + ours + `
			AND NOT p.prosecdef AND p.proconfig IS NOT NULL`); len(bad) > 0 {
			t.Errorf("helpers with settings of their own: %v", bad)
		}
		n := d.value(t, `SELECT count(*)`+ours+` AND p.prosecdef`)
		if n != int64(68) {
			t.Errorf("%v functions for the API, want 68", n)
		}
	})

	t.Run("the API role can execute exactly those, and PUBLIC none", func(t *testing.T) {
		if bad := strings_(`SELECT p.oid::regprocedure::text`+ours+`
			AND has_function_privilege($1, p.oid, 'EXECUTE') <> p.prosecdef`, d.apiUser); len(bad) > 0 {
			t.Errorf("the API role's EXECUTE is wrong on: %v", bad)
		}
		if bad := strings_(`SELECT p.oid::regprocedure::text` + ours + `
			AND EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) x
			            WHERE x.grantee = 0 AND x.privilege_type = 'EXECUTE')`); len(bad) > 0 {
			t.Errorf("PUBLIC can execute: %v", bad)
		}
	})

	t.Run("each takes the request first", func(t *testing.T) {
		if bad := strings_(`SELECT p.oid::regprocedure::text` + ours + `
			AND p.prosecdef
			AND (p.pronargs = 0 OR p.proargtypes[0] <> 'public.request'::regtype)
			AND p.oid <> 'meta.schema_version()'::regprocedure`); len(bad) > 0 {
			t.Errorf("without the request first: %v", bad)
		}
	})

	// create and delete are reserved words, allowed after the schema's dot.
	t.Run("names that are reserved words", func(t *testing.T) {
		at := newAccessorTenant(t, "catalogue")
		class := at.admin.id(t, "class.create", "Things", nil, false)
		item := at.user.id(t, "item.create", class, "Thing", nil, false, "{}")
		if _, err := at.user.call(t, "item.delete", item); err != nil {
			t.Error(err)
		}
	})
}

// ---------------------------------------------------------------------------
// Sessions and roles
// ---------------------------------------------------------------------------

func TestAccessorSessions(t *testing.T) {
	at := newAccessorTenant(t, "sessions")
	d := at.admin.d

	t.Run("an unknown host, no session, a wrong token", func(t *testing.T) {
		_, err := caller{d: d, host: "nobody"}.call(t, "account.me")
		wantState(t, err, "P0002", `No tenant has the host "nobody"`)
		_, err = caller{d: d, host: "sessions"}.call(t, "account.me")
		wantState(t, err, "28000", "Not logged in")
		_, err = caller{d: d, host: "sessions", token: "wrong"}.call(t, "account.me")
		wantState(t, err, "28000", "Not logged in")
		// Another tenant's session isn't valid here.
		other := newAccessorTenant(t, "sessions-other")
		_, err = caller{d: d, host: "sessions", token: other.admin.token}.call(t, "account.me")
		wantState(t, err, "28000", "Not logged in")
	})

	t.Run("roles", func(t *testing.T) {
		_, err := at.viewer.call(t, "class.create", "Tools", nil, false)
		wantState(t, err, "42501", "This needs the role admin; you are viewer")
		_, err = at.user.call(t, "class.create", "Tools", nil, false)
		wantState(t, err, "42501", "you are user")
		class := at.admin.id(t, "class.create", "Tools", nil, false)
		_, err = at.viewer.call(t, "item.create", class, "Drill", nil, false, "{}")
		wantState(t, err, "42501", "you are viewer")
		at.user.must(t, "item.create", class, "Drill", nil, false, "{}")
	})

	t.Run("a session expires after max_idle unused", func(t *testing.T) {
		c := caller{d: d, host: "sessions", address: "192.0.2.9"}
		answer := c.must(t, "account.login", "user@sessions.example", "password", "short", "1 hour")
		c.token = str(t, answer, "token")
		c.must(t, "account.me")
		d.mustExec(t, "UPDATE public.session SET last_used = now() - interval '2 hours' WHERE client = 'short'")
		_, err := c.call(t, "account.me")
		wantState(t, err, "28000", "expired")
	})

	t.Run("the address trail and one's own sessions", func(t *testing.T) {
		moved := at.user
		moved.address = "198.51.100.7"
		moved.must(t, "account.me")
		list := at.user.must(t, "account.session_list").([]any)
		var current map[string]any
		for _, s := range list {
			if get(t, s, "current") == true {
				current = s.(map[string]any)
			}
		}
		if current == nil {
			t.Fatalf("no current session in %v", list)
		}
		var addresses []string
		for _, u := range current["usage"].([]any) {
			addresses = append(addresses, str(t, u, "address"))
		}
		if strings.Join(addresses, " ") != "198.51.100.7 192.0.2.1" {
			t.Errorf("trail %v, newest first", addresses)
		}
		if current["max_idle"] != nil || current["expires"] != nil {
			t.Errorf("a session that never expires: %v", current)
		}
	})

	t.Run("logging out other sessions", func(t *testing.T) {
		second := caller{d: d, host: "sessions"}
		second.token = str(t, second.must(t, "account.login", "viewer@sessions.example", "password", "second", nil), "token")
		ended := at.viewer.must(t, "account.session_logout_others")
		if ended != float64(1) {
			t.Errorf("ended %v sessions, want 1", ended)
		}
		_, err := second.call(t, "account.me")
		wantState(t, err, "28000", "Not logged in")
		at.viewer.must(t, "account.me")
	})

	t.Run("a new password ends the other sessions only if asked", func(t *testing.T) {
		second := caller{d: d, host: "sessions"}
		second.token = str(t, second.must(t, "account.login", "user@sessions.example", "password", "second", nil), "token")
		_, err := at.user.call(t, "account.password_change", "password", "new password 1", nil)
		wantState(t, err, "22023", "Say whether the other sessions should end")
		at.user.must(t, "account.password_change", "password", "new password 1", false)
		second.must(t, "account.me")
		at.user.must(t, "account.password_change", "new password 1", "new password 2", true)
		_, err = second.call(t, "account.me")
		wantState(t, err, "28000", "Not logged in")
		at.user.must(t, "account.me")
	})

	t.Run("an admin's new password for another says whether sessions end", func(t *testing.T) {
		users := at.admin.must(t, "account.list").([]any)
		var viewer string
		for _, u := range users {
			if str(t, u, "role") == "viewer" {
				viewer = str(t, u, "id")
			}
		}
		_, err := at.admin.call(t, "account.patch", viewer, `{"password": "another password"}`)
		wantState(t, err, "22023", "end_sessions")
		_, err = at.admin.call(t, "account.patch", viewer, `{"end_sessions": true}`)
		wantState(t, err, "22023", "only goes with a new password")
		_, err = at.admin.call(t, "account.patch", at.adminAccount, `{"password": "another password", "end_sessions": false}`)
		wantState(t, err, "22023", "your current one")
		at.admin.must(t, "account.patch", viewer, `{"password": "another password", "end_sessions": true}`)
		_, err = at.viewer.call(t, "account.me")
		wantState(t, err, "28000", "Not logged in")
	})
}

// ---------------------------------------------------------------------------
// Tenants stay apart
// ---------------------------------------------------------------------------

// For every function that takes an id, another tenant's id is "not found"
// (in the path) or a bad reference (in the body).
func TestAccessorTenantIsolation(t *testing.T) {
	mine := newAccessorTenant(t, "isolation")
	theirs := newAccessorTenant(t, "isolation-other")

	// Their objects.
	attribute := theirs.admin.id(t, "attribute.create", "Colour", "choice", nil, false)
	option := theirs.admin.id(t, "attribute.option_create", attribute, "Red")
	class := theirs.admin.id(t, "class.create", "Tools", nil, false)
	theirs.admin.must(t, "class.assign", class, attribute, nil, "item", false)
	location := theirs.admin.id(t, "location.create", "Shed", nil, false, nil, nil, nil)
	item := theirs.user.id(t, "item.create", class, "Hammer", nil, false, "{}")
	stock := theirs.user.id(t, "stock.create", item, location, 1, "{}")
	account := theirs.adminAccount

	notFound := []struct {
		fn   string
		args []any
	}{
		{"attribute.get", []any{attribute}},
		{"attribute.patch", []any{attribute, `{"name": "x"}`}},
		{"attribute.delete", []any{attribute}},
		{"attribute.option_get", []any{option}},
		{"attribute.option_patch", []any{option, `{"name": "x"}`}},
		{"attribute.option_delete", []any{option}},
		{"class.get", []any{class}},
		{"class.patch", []any{class, `{"name": "x"}`}},
		{"class.delete", []any{class}},
		{"class.delete_tree", []any{class, false, true}},
		{"class.unassign", []any{class, attribute}},
		{"location.get", []any{location}},
		{"location.patch", []any{location, `{"name": "x"}`}},
		{"location.delete", []any{location}},
		{"item.get", []any{item}},
		{"item.patch", []any{item, `{"name": "x"}`}},
		{"item.delete", []any{item}},
		{"item.value_set", []any{item, attribute, `"Red"`}},
		{"stock.get", []any{stock}},
		{"stock.patch", []any{stock, `{"amount": 2}`}},
		{"stock.move", []any{stock, location, nil}},
		{"stock.merge", []any{stock, stock, nil}},
		{"stock.delete", []any{stock}},
		{"account.get", []any{account}},
		{"account.patch", []any{account, `{"role": "viewer"}`}},
		{"account.delete", []any{account}},
		{"attachment.get", []any{"item", item, attribute}},
	}
	for _, c := range notFound {
		if _, err := mine.admin.call(t, c.fn, c.args...); sqlState(err) != "P0002" {
			t.Errorf("%s of another tenant's: %v, want not found", c.fn, err)
		}
	}

	myClass := mine.admin.id(t, "class.create", "Mine", nil, false)
	myLocation := mine.admin.id(t, "location.create", "Mine", nil, false, nil, nil, nil)
	myItem := mine.user.id(t, "item.create", myClass, "Mine", nil, false, "{}")
	badReference := []struct {
		fn   string
		args []any
	}{
		{"class.create", []any{"Below theirs", class, false}},
		{"class.assign", []any{myClass, attribute, nil, "item", false}},
		{"item.create", []any{class, "In their class", nil, false, "{}"}},
		{"item.create", []any{myClass, "With their attribute", nil, false, fmt.Sprintf(`{"%s": "Red"}`, attribute)}},
		{"location.create", []any{"In theirs", location, false, nil, nil, nil}},
		{"stock.create", []any{item, myLocation, 1, "{}"}},
		{"stock.create", []any{myItem, location, 1, "{}"}},
	}
	for _, c := range badReference {
		if _, err := mine.admin.call(t, c.fn, c.args...); sqlState(err) != "23503" {
			t.Errorf("%s with another tenant's id in the body: %v, want a bad reference", c.fn, err)
		}
	}

	if code := theirs.user.must(t, "stock.get", stock); code != nil {
		if _, err := mine.user.call(t, "code.resolve", str(t, code, "code")); sqlState(err) != "P0002" {
			t.Errorf("their code resolved for me: %v", err)
		}
	}
}

// ---------------------------------------------------------------------------
// Deleting, merging and the labels of deleted things
// ---------------------------------------------------------------------------

func TestAccessorDeleting(t *testing.T) {
	at := newAccessorTenant(t, "deleting")
	admin, user := at.admin, at.user

	tools := admin.id(t, "class.create", "Tools", nil, false)
	drills := admin.id(t, "class.create", "Drills", tools, false)
	shed := admin.id(t, "location.create", "Shed", nil, false, nil, nil, nil)
	drill := user.id(t, "item.create", drills, "Drill", nil, false, "{}")
	stock := user.id(t, "stock.create", drill, shed, 1, "{}")

	t.Run("what is in the way is named", func(t *testing.T) {
		_, err := admin.call(t, "class.delete", tools)
		wantState(t, err, "23001", `Class "Tools" still has subclasses`)
		_, err = admin.call(t, "class.delete", drills)
		wantState(t, err, "23001", `Class "Drills" still has items`)
		_, err = user.call(t, "item.delete", drill)
		wantState(t, err, "23001", `Item "Drill" still has stock`)
		_, err = admin.call(t, "location.delete", shed)
		wantState(t, err, "23001", `Location "Shed" still has stock`)
	})

	t.Run("a tree goes with everything below it, when forced", func(t *testing.T) {
		_, err := admin.call(t, "class.delete_tree", tools, false, false)
		wantState(t, err, "23001", "Tools/Drills (1 item)")
		dry := admin.must(t, "class.delete_tree", tools, true, true)
		if n := len(get(t, dry, "classes").([]any)); n != 2 || num(t, dry, "stock") != 1 {
			t.Errorf("dry run: %v", dry)
		}
		admin.must(t, "class.delete_tree", tools, true, false)
		for _, fn := range []struct{ name, id string }{
			{"class.get", tools}, {"class.get", drills}, {"item.get", drill}, {"stock.get", stock},
		} {
			if _, err := admin.call(t, fn.name, fn.id); sqlState(err) != "P0002" {
				t.Errorf("%s %s after the delete: %v, want not found", fn.name, fn.id, err)
			}
		}
	})

	t.Run("a deleted thing's label is gone, one never handed out not found", func(t *testing.T) {
		things := admin.id(t, "class.create", "Things", nil, false)
		box := user.must(t, "item.create", things, "Box", nil, false, "{}")
		code := str(t, box, "code")
		user.must(t, "item.delete", str(t, box, "id"))
		_, err := user.call(t, "code.resolve", code)
		wantState(t, err, "WT001", "has been deleted")
		_, err = user.call(t, "code.resolve", "ZZZZ")
		wantState(t, err, "P0002", "")
		_, err = user.call(t, "code.resolve", "0FFF")
		wantState(t, err, "P0002", "")
	})

	t.Run("an attribute or option in use is named, and goes when it isn't", func(t *testing.T) {
		size := admin.id(t, "attribute.create", "Size", "choice", nil, false)
		small := admin.id(t, "attribute.option_create", size, "Small")
		bins := admin.id(t, "class.create", "Bins", nil, false)
		admin.must(t, "class.assign", bins, size, `"Small"`, "item", false)
		_, err := admin.call(t, "attribute.option_delete", small)
		wantState(t, err, "23001", `Option "Small" is still in use: it is the default of class "Bins"`)
		_, err = admin.call(t, "attribute.delete", size)
		wantState(t, err, "23001", `Attribute "Size" is still in use: class "Bins" has it`)
		admin.must(t, "class.unassign", bins, size)
		admin.must(t, "attribute.delete", size)
		if _, err := admin.call(t, "attribute.option_get", small); sqlState(err) != "P0002" {
			t.Errorf("the option outlived its attribute: %v", err)
		}
	})
}

func TestAccessorMerge(t *testing.T) {
	at := newAccessorTenant(t, "merge")
	admin, user := at.admin, at.user

	parts := admin.id(t, "class.create", "Parts", nil, false)
	serial := admin.id(t, "attribute.create", "Batch", "text", nil, false)
	admin.must(t, "class.assign", parts, serial, nil, "stock", false)
	shelf := admin.id(t, "location.create", "Shelf", nil, false, nil, nil, nil)
	bin := admin.id(t, "location.create", "Bin", nil, false, nil, nil, nil)
	screw := user.id(t, "item.create", parts, "Screw", nil, false, "{}")
	nut := user.id(t, "item.create", parts, "Nut", nil, false, "{}")
	batch := func(b string) string { return fmt.Sprintf(`{"%s": "%s"}`, serial, b) }

	t.Run("a move never merges", func(t *testing.T) {
		a := user.id(t, "stock.create", screw, shelf, 5, "{}")
		b := user.id(t, "stock.create", screw, bin, 5, "{}")
		moved := user.must(t, "stock.move", a, bin, nil)
		if str(t, moved, "id") != a || num(t, moved, "amount") != 5 {
			t.Errorf("moved: %v", moved)
		}
		user.must(t, "stock.delete", a)
		user.must(t, "stock.delete", b)
	})

	t.Run("part of a row, then all of it", func(t *testing.T) {
		from := user.must(t, "stock.create", screw, shelf, 10, batch("B1"))
		into := user.id(t, "stock.create", screw, bin, 1, batch("B1"))
		merged := user.must(t, "stock.merge", str(t, from, "id"), into, 4)
		if str(t, merged, "id") != into || num(t, merged, "amount") != 5 {
			t.Errorf("after merging 4: %v", merged)
		}
		if n := num(t, user.must(t, "stock.get", str(t, from, "id")), "amount"); n != 6 {
			t.Errorf("the source has %v left, want 6", n)
		}
		merged = user.must(t, "stock.merge", str(t, from, "id"), into, nil)
		if num(t, merged, "amount") != 11 {
			t.Errorf("after merging the rest: %v", merged)
		}
		_, err := user.call(t, "code.resolve", str(t, from, "code"))
		wantState(t, err, "WT001", "has been deleted")
	})

	t.Run("refused unless the same item, counted, with the same values", func(t *testing.T) {
		a := user.id(t, "stock.create", screw, shelf, 2, batch("B2"))
		b := user.id(t, "stock.create", screw, bin, 2, batch("B3"))
		other := user.id(t, "stock.create", nut, bin, 2, batch("B2"))
		uncounted := user.id(t, "stock.create", screw, bin, nil, batch("B2"))
		_, err := user.call(t, "stock.merge", a, b, nil)
		wantState(t, err, "23514", "have different values for Batch")
		_, err = user.call(t, "stock.merge", a, other, nil)
		wantState(t, err, "23514", "are of different items")
		_, err = user.call(t, "stock.merge", a, uncounted, nil)
		wantState(t, err, "23514", "Only counted stock rows can be merged")
		_, err = user.call(t, "stock.merge", a, a, nil)
		wantState(t, err, "23514", "can't be merged into itself")
		_, err = user.call(t, "stock.merge", a, b, 3)
		wantState(t, err, "23514", "have different values")
	})

	t.Run("the attachments go along with a whole row", func(t *testing.T) {
		from := user.id(t, "stock.create", screw, shelf, 1, batch("B4"))
		into := user.id(t, "stock.create", screw, bin, 1, batch("B4"))
		ctx := context.Background()
		d := database(t)
		var photo string
		if err := d.dba.QueryRow(ctx, `
			INSERT INTO public.attachment (stock, media_type, hash, size, title)
			VALUES ($1, 'image/png', repeat('ab', 32), 10, 'Receipt') RETURNING id`, from).Scan(&photo); err != nil {
			t.Fatal(err)
		}
		d.mustExec(t, "UPDATE public.stock SET photo = $2 WHERE id = $1", from, photo)
		merged := user.must(t, "stock.merge", from, into, nil)
		if n := len(get(t, merged, "attachments").([]any)); n != 1 || get(t, merged, "photo") != nil {
			t.Errorf("the merged row's attachments and photo: %v %v", get(t, merged, "attachments"), get(t, merged, "photo"))
		}
	})
}

// ---------------------------------------------------------------------------
// Items, values and the list
// ---------------------------------------------------------------------------

func TestAccessorItems(t *testing.T) {
	at := newAccessorTenant(t, "items")
	admin, user := at.admin, at.user
	mm := database(t).value(t, `
		SELECT u.id::text FROM public.unit u JOIN public.unit_family f ON f.id = u.family
		WHERE f.name = 'Metric length' AND u.symbol = 'mm'`).(string)

	// Locked, so that its numbers are always shown in millimetres.
	length := admin.id(t, "attribute.create", "Length", "decimal", mm, true)
	colour := admin.id(t, "attribute.create", "Colour", "choice", nil, false)
	red := admin.id(t, "attribute.option_create", colour, "Red")
	admin.must(t, "attribute.option_create", colour, "Blue")
	serial := admin.id(t, "attribute.create", "Serial", "text", nil, false)
	screws := admin.id(t, "class.create", "Screws", nil, false)
	admin.must(t, "class.assign", screws, length, nil, "item", false)
	admin.must(t, "class.assign", screws, colour, `"Blue"`, "item", false)
	admin.must(t, "class.assign", screws, serial, nil, "stock", true)
	shelf := admin.id(t, "location.create", "Shelf", nil, false, 2, 3, nil)

	for i, name := range []string{"Screw 10", "Screw 2", "Screw 1"} {
		values := fmt.Sprintf(`{"%s": %d}`, length, (i+1)*10)
		if i == 0 {
			values = fmt.Sprintf(`{"%s": 0.01, "%s": "%s"}`, length, colour, red)
		}
		user.must(t, "item.create", screws, name, nil, false, values)
	}

	t.Run("names sort by their numbers", func(t *testing.T) {
		page := user.must(t, "item.list", nil, nil, nil, 10, 0)
		var names []string
		for _, r := range get(t, page, "rows").([]any) {
			names = append(names, str(t, r, "name"))
		}
		if strings.Join(names, ",") != "Screw 1,Screw 2,Screw 10" {
			t.Errorf("%v", names)
		}
		if num(t, page, "total") != 3 {
			t.Errorf("total %v", get(t, page, "total"))
		}
	})

	t.Run("search and filters", func(t *testing.T) {
		count := func(search any, where any) float64 {
			return num(t, user.must(t, "item.list", nil, search, where, 10, 0), "total")
		}
		if n := count("screws", nil); n != 3 {
			t.Errorf("search by class name: %v", n)
		}
		if n := count("red", nil); n != 1 {
			t.Errorf("search by option: %v", n)
		}
		if n := count("blue", nil); n != 2 {
			t.Errorf("search by the class default: %v", n)
		}
		if n := count("2 screw", nil); n != 1 {
			t.Errorf("two words: %v", n)
		}
		// In the base unit, metres: 0.01, 20 and 30.
		if n := count(nil, fmt.Sprintf(`[{"attribute": "%s", "op": ">", "value": 15}]`, length)); n != 2 {
			t.Errorf("number filter: %v", n)
		}
		if n := count(nil, fmt.Sprintf(`[{"attribute": "%s", "op": "=", "value": "Blue"}]`, colour)); n != 2 {
			t.Errorf("choice filter on the default: %v", n)
		}
		_, err := user.call(t, "item.list", nil, nil, fmt.Sprintf(`[{"attribute": "%s", "op": "contains", "value": 1}]`, length), 10, 0)
		wantState(t, err, "22023", "Length can be compared with")
	})

	t.Run("a number is shown in the unit that suits it", func(t *testing.T) {
		item := user.must(t, "item.list", nil, "Screw 10", nil, 10, 0)
		full := user.must(t, "item.get", str(t, item, "rows", 0, "id"))
		for _, v := range get(t, full, "values").([]any) {
			if str(t, v, "attribute", "name") == "Length" {
				if num(t, v, "display", "value") != 10 || str(t, v, "display", "unit") != mm {
					t.Errorf("display %v", get(t, v, "display"))
				}
			}
		}
	})

	t.Run("stock: required values, incomplete, moves", func(t *testing.T) {
		page := user.must(t, "item.list", nil, "Screw 1", nil, 10, 0)
		screw := str(t, page, "rows", 0, "id")
		compartments := get(t, admin.must(t, "location.list", nil), "nodes").([]any)
		var a1, b1 string
		for _, n := range compartments {
			switch str(t, n, "name") {
			case "A1":
				a1 = str(t, n, "id")
			case "B1":
				b1 = str(t, n, "id")
			}
		}
		if a1 == "" || b1 == "" || len(compartments) != 7 {
			t.Fatalf("the grid made %d locations", len(compartments))
		}
		_, err := user.call(t, "stock.create", screw, shelf, 5, "{}")
		wantState(t, err, "23514", `Location "Shelf" is a container`)
		_, err = user.call(t, "stock.create", screw, a1, 5, "{}")
		wantState(t, err, "23514", "missing required attributes: Serial")
		row := user.id(t, "stock.create", screw, a1, 5, fmt.Sprintf(`{"%s": "S1"}`, serial))
		moved := user.must(t, "stock.move", row, b1, 2)
		if str(t, moved, "location") != b1 || num(t, moved, "amount") != 2 {
			t.Errorf("moved part: %v", moved)
		}
		page = user.must(t, "item.list", nil, "Screw 1", nil, 10, 0)
		if num(t, page, "rows", 0, "stock", "total") != 5 || get(t, page, "rows", 0, "incomplete") != false {
			t.Errorf("after the move: %v", get(t, page, "rows", 0))
		}
	})
}

// ---------------------------------------------------------------------------
// Model files
// ---------------------------------------------------------------------------

func TestAccessorModelImport(t *testing.T) {
	at := newAccessorTenant(t, "model")
	admin := at.admin
	file := `{
		"format": "wtf-model", "version": 1,
		"quantities": [{
			"name": "Thickness", "datatype": "decimal", "base_unit": {"symbol": "thk", "name": "thickness unit"},
			"families": [{"name": "Thickness", "units": [
				{"symbol": "thk", "name": "thickness unit", "factor": "1"},
				{"symbol": "kthk", "name": "kilo thickness", "factor": "1000"}]}]
		}],
		"attributes": [
			{"name": "Thickness", "unit": "kthk"},
			{"name": "Finish", "datatype": "choice", "options": ["Matt", "Gloss"]}
		],
		"classes": [{"name": "Boards", "attributes": [
			{"attribute": "Thickness", "default": 2},
			{"attribute": "Finish", "scope": "stock", "required": true}
		]}]
	}`

	dry := admin.must(t, "model.import", file, nil, true)
	if get(t, dry, "applied") != false || len(get(t, dry, "conflicts").([]any)) != 0 {
		t.Fatalf("dry run: %v", dry)
	}
	if n := len(admin.must(t, "attribute.list").([]any)); n != 0 {
		t.Fatalf("a dry run kept %d attributes", n)
	}

	report := admin.must(t, "model.import", file, nil, false)
	if get(t, report, "applied") != true {
		t.Fatalf("import: %v", report)
	}
	if n := len(get(t, report, "units", "added").([]any)); n != 2 {
		t.Errorf("%d units added", n)
	}
	if n := len(get(t, report, "options", "added").([]any)); n != 2 {
		t.Errorf("%d options added", n)
	}

	again := admin.must(t, "model.import", file, nil, false)
	for _, kind := range []string{"quantities", "families", "units", "attributes", "classes", "assignments"} {
		if added := get(t, again, kind, "added").([]any); len(added) != 0 {
			t.Errorf("imported again, %s added: %v", kind, added)
		}
	}

	t.Run("an export imports as the same", func(t *testing.T) {
		classes := get(t, admin.must(t, "class.list", nil), "nodes").([]any)
		exported := admin.must(t, "model.export", str(t, classes, 0, "id"))
		data, _ := json.Marshal(exported)
		report := admin.must(t, "model.import", string(data), nil, true)
		if conflicts := get(t, report, "conflicts").([]any); len(conflicts) != 0 {
			t.Errorf("conflicts importing the export: %v", conflicts)
		}
		if str(t, exported, "classes", 0, "attributes", 0, "attribute") != "Finish" ||
			str(t, exported, "classes", 0, "attributes", 0, "scope") != "stock" {
			t.Errorf("exported %v", get(t, exported, "classes", 0, "attributes"))
		}
	})

	t.Run("conflicts", func(t *testing.T) {
		changed := strings.Replace(file, `"datatype": "choice"`, `"datatype": "text"`, 1)
		changed = strings.Replace(changed, `"options": ["Matt", "Gloss"]`, `"options": []`, 1)
		report := admin.must(t, "model.import", changed, nil, false)
		if get(t, report, "applied") != false || len(get(t, report, "conflicts").([]any)) == 0 {
			t.Errorf("an attribute of another datatype: %v", report)
		}
	})

	t.Run("a quantity without its base unit", func(t *testing.T) {
		missing := strings.ReplaceAll(file, `"Thickness"`, `"Depth"`)
		missing = strings.Replace(missing, `{"symbol": "thk", "name": "thickness unit", "factor": "1"},`, ``, 1)
		missing = strings.Replace(missing, `"Boards"`, `"Panels"`, 1)
		missing = strings.Replace(missing, `"Finish"`, `"Coat"`, 2)
		report := admin.must(t, "model.import", missing, nil, false)
		found := false
		for _, c := range get(t, report, "conflicts").([]any) {
			if strings.Contains(str(t, c, "message"), "must be one of Depth's units") {
				found = true
			}
		}
		if !found {
			t.Errorf("conflicts %v", get(t, report, "conflicts"))
		}
	})
}
