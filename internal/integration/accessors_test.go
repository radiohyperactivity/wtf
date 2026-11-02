package integration

// Tests of the functions the API calls (the accessors, db/repeatable/), on
// the database alone: each is called as the API's role does, with a
// request (token, address) as its first argument. Plus checks that hold
// for every function, read from the catalogue.

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// caller makes calls as one session.
type caller struct {
	d       *testDatabase
	token   string // "" for none
	address string
}

// call calls function fn with the request first and args after it, as the
// API role, and returns its JSON answer decoded (nil for none).
func (c caller) call(t *testing.T, fn string, args ...any) (any, error) {
	t.Helper()
	var sql strings.Builder
	fmt.Fprintf(&sql, "SELECT %s(ROW($1::text, $2::inet)::public.request", fn)
	for i := range args {
		fmt.Fprintf(&sql, ", $%d", i+3)
	}
	sql.WriteString(")::text")
	params := append([]any{orNull(c.token), orNull(c.address)}, args...)
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

// orNull turns "" into SQL NULL.
func orNull(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// accessors is an admin, a user and a viewer, logged in, for a test that
// calls the accessors.
type accessors struct {
	admin, user, viewer caller
	adminAccount        string
}

// newAccessors empties the data (d.reset), and makes three accounts named
// after name (admin@<name>.example and so on), with passwords hashed at a
// low bcrypt cost so that tests stay quick, each logged in through
// account.login.
func newAccessors(t *testing.T, name string) accessors {
	t.Helper()
	d := database(t)
	d.reset(t)
	var at accessors
	for _, role := range []string{"admin", "user", "viewer"} {
		email := role + "@" + name + ".example"
		d.mustExec(t, "DELETE FROM public.account WHERE email = $1", email)
		account := d.id(t, `
			INSERT INTO public.account (email, password_hash, role)
			VALUES ($1, extensions.crypt('password', extensions.gen_salt('bf', 4)), $2)
			RETURNING id`, email, role)
		c := caller{d: d, address: "192.0.2.1"}
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

	t.Run("no triggers", func(t *testing.T) {
		if bad := strings_(`SELECT t.tgname::text FROM pg_trigger t
			JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
			WHERE n.nspname = 'public' AND NOT t.tgisinternal`); len(bad) > 0 {
			t.Errorf("triggers: %v", bad)
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
		if n != int64(50) {
			t.Errorf("%v functions for the API, want 50", n)
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
		at := newAccessors(t, "catalogue")
		class := at.admin.id(t, "class.create", "Things", nil, false)
		item := at.user.id(t, "item.create", class, "Thing", nil, "{}")
		if _, err := at.user.call(t, "item.delete", item); err != nil {
			t.Error(err)
		}
	})
}

// ---------------------------------------------------------------------------
// Sessions and roles
// ---------------------------------------------------------------------------

func TestAccessorSessions(t *testing.T) {
	at := newAccessors(t, "sessions")
	d := at.admin.d

	t.Run("no session, a wrong token", func(t *testing.T) {
		_, err := caller{d: d}.call(t, "account.me")
		wantState(t, err, "28000", "Not logged in")
		_, err = caller{d: d, token: "wrong"}.call(t, "account.me")
		wantState(t, err, "28000", "Not logged in")
	})

	t.Run("roles", func(t *testing.T) {
		_, err := at.viewer.call(t, "class.create", "Tools", nil, false)
		wantState(t, err, "42501", "This needs the role admin; you are viewer")
		_, err = at.user.call(t, "class.create", "Tools", nil, false)
		wantState(t, err, "42501", "you are user")
		class := at.admin.id(t, "class.create", "Tools", nil, false)
		_, err = at.viewer.call(t, "item.create", class, "Drill", nil, "{}")
		wantState(t, err, "42501", "you are viewer")
		at.user.must(t, "item.create", class, "Drill", nil, "{}")
	})

	t.Run("emails are in lower case, and once", func(t *testing.T) {
		c := caller{d: d}
		if get(t, c.must(t, "account.login", " USER@Sessions.example", "password", "case", nil), "ok") != true {
			t.Error("login with another letter case failed")
		}
		_, err := at.admin.call(t, "account.create", "Viewer@SESSIONS.example", nil, "viewer")
		wantState(t, err, "23505", "viewer@sessions.example already")
	})

	t.Run("a session expires after max_idle unused", func(t *testing.T) {
		c := caller{d: d, address: "192.0.2.9"}
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
		second := caller{d: d}
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
		second := caller{d: d}
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
			if str(t, u, "email") == "viewer@sessions.example" {
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
// Deleting, and the labels of deleted things
// ---------------------------------------------------------------------------

func TestAccessorDeleting(t *testing.T) {
	at := newAccessors(t, "deleting")
	admin, user := at.admin, at.user

	tools := admin.id(t, "class.create", "Tools", nil, false)
	drills := admin.id(t, "class.create", "Drills", tools, false)
	shed := admin.id(t, "location.create", "Shed", nil, false, nil, nil, nil)
	drill := user.id(t, "item.create", drills, "Drill", nil, "{}")
	stock := user.id(t, "stock.create", drill, shed, 1, nil, nil, "{}")

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
		box := user.must(t, "item.create", things, "Box", nil, "{}")
		code := str(t, box, "code")
		user.must(t, "item.delete", str(t, box, "id"))
		_, err := user.call(t, "code.resolve", code)
		wantState(t, err, "WT001", "has been deleted")
		_, err = user.call(t, "code.resolve", "ZZZZ")
		wantState(t, err, "P0002", "")
		_, err = user.call(t, "code.resolve", "0FFF")
		wantState(t, err, "P0002", "")
	})

	t.Run("containers", func(t *testing.T) {
		boxes := admin.id(t, "class.create", "Boxes", nil, true)
		_, err := user.call(t, "item.create", boxes, "Box", nil, "{}")
		wantState(t, err, "23514", "is a container")
		things := admin.id(t, "class.create", "Stuff", nil, false)
		user.must(t, "item.create", things, "Thing", nil, "{}")
		_, err = admin.call(t, "class.patch", things, `{"container": true}`)
		wantState(t, err, "23514", "can't become a container")
		room := admin.id(t, "location.create", "Room", nil, true, nil, nil, nil)
		_, err = user.call(t, "stock.create", str(t, user.must(t, "item.create", things, "Other", nil, "{}"), "id"),
			room, 1, nil, nil, "{}")
		wantState(t, err, "23514", "is a container")
	})
}
