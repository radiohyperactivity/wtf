package integration

// Tests of the database's rules (db/repeatable/, the trigger functions, and
// the foreign keys they rely on), on the schema alone: rows are written as
// the DBA role, each change in a transaction of its own. For each rule a
// change it allows and one it refuses; the gaps the refactor's review
// closed; and a race the row locks close, shown with two connections.

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// rules builds the rows of one tenant for the tests of the rules.
type rules struct {
	d      *testDatabase
	tenant string
}

func newRules(t *testing.T, host string) rules {
	t.Helper()
	d := database(t)
	return rules{d: d, tenant: d.newTenant(t, host)}
}

// orNull turns "" into SQL NULL.
func orNull(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func (r rules) class(t *testing.T, name, parent string) string {
	t.Helper()
	return r.d.id(t, "INSERT INTO public.class (tenant, parent, name) VALUES ($1, $2, $3) RETURNING id",
		r.tenant, orNull(parent), name)
}

func (r rules) attribute(t *testing.T, name, datatype, unit string) string {
	t.Helper()
	return r.d.id(t, "INSERT INTO public.attribute (tenant, name, datatype, unit) VALUES ($1, $2, $3, $4) RETURNING id",
		r.tenant, name, datatype, orNull(unit))
}

func (r rules) option(t *testing.T, attribute, name string) string {
	t.Helper()
	return r.d.id(t, "INSERT INTO public.attribute_option (attribute, name) VALUES ($1, $2) RETURNING id",
		attribute, name)
}

func (r rules) assign(t *testing.T, class, attribute, scope string, required bool) {
	t.Helper()
	r.d.mustExec(t, "INSERT INTO public.class_attribute (class, attribute, scope, required) VALUES ($1, $2, $3, $4)",
		class, attribute, scope, required)
}

func (r rules) item(t *testing.T, class, name string) string {
	t.Helper()
	return r.d.id(t, "INSERT INTO public.item (code, class, name) VALUES (tenant.take_codes($1, 1), $2, $3) RETURNING id",
		r.tenant, class, name)
}

func (r rules) location(t *testing.T, name, parent string) string {
	t.Helper()
	return r.d.id(t, `INSERT INTO public.location (tenant, code, parent, name)
		 VALUES ($1, tenant.take_codes($1, 1), $2, $3) RETURNING id`,
		r.tenant, orNull(parent), name)
}

func (r rules) stock(t *testing.T, item, location string, amount any) string {
	t.Helper()
	return r.d.id(t, "INSERT INTO public.stock (code, item, location, amount) VALUES (tenant.take_codes($1, 1), $2, $3, $4) RETURNING id",
		r.tenant, item, location, amount)
}

// remove deletes row id of table, and returns the error.
func (r rules) remove(t *testing.T, table, id string) error {
	t.Helper()
	return r.d.exec(t, "DELETE FROM public."+table+" WHERE id = $1", id)
}

// unit returns the id of a global unit, by family name and symbol.
func (r rules) unit(t *testing.T, family, symbol string) string {
	t.Helper()
	return r.d.value(t, `
		SELECT u.id::text FROM public.unit u JOIN public.unit_family f ON f.id = u.family
		WHERE f.name = $1 AND u.symbol = $2 AND u.tenant IS NULL`, family, symbol).(string)
}

func (r rules) version(t *testing.T, name string) int64 {
	t.Helper()
	return r.d.value(t, `
		SELECT coalesce((SELECT version FROM public.data_version WHERE tenant = $1 AND name = $2), 1)`,
		r.tenant, name).(int64)
}

// ---------------------------------------------------------------------------
// Units
// ---------------------------------------------------------------------------

// The bootstrap units were inserted before the rules existed, so they are
// checked here against what the rules require of a base unit.
func TestBootstrapUnits(t *testing.T) {
	d := database(t)
	if n := d.value(t, "SELECT count(*) FROM public.quantity WHERE tenant IS NULL"); n != int64(16) {
		t.Errorf("%v global quantities, want 16", n)
	}
	if bad := d.value(t, `
		SELECT count(*) FROM public.quantity q
		JOIN public.unit u        ON u.id = q.base_unit
		JOIN public.unit_family f ON f.id = u.family
		WHERE f.quantity <> q.id OR u.base_factor <> 1 OR u.base_offset <> 0`); bad != int64(0) {
		t.Errorf("%v quantities have a base unit that isn't theirs, or not with factor 1 and offset 0", bad)
	}
	if got := d.value(t, `
		SELECT string_agg(u.symbol, ' ' ORDER BY u.base_factor)
		FROM public.unit u JOIN public.unit_family f ON f.id = u.family
		WHERE f.name = 'Charge'`); got != "C mAh Ah" {
		t.Errorf("Charge has %q, want C, mAh and Ah", got)
	}
	if got := d.value(t, `
		SELECT u.symbol FROM public.quantity q JOIN public.unit u ON u.id = q.base_unit
		WHERE q.name = 'Bytes'`); got != "B" {
		t.Errorf("the base unit of Bytes is %q", got)
	}
}

func TestUnitRules(t *testing.T) {
	r := newRules(t, "rules-units")
	other := r.d.newTenant(t, "rules-units-other")
	length := r.d.value(t, "SELECT id::text FROM public.quantity WHERE name = 'Length' AND tenant IS NULL").(string)

	t.Run("a tenant's quantity can't have a global quantity's name", func(t *testing.T) {
		err := r.d.exec(t, `
			WITH q AS (INSERT INTO public.quantity (tenant, name, datatype, base_unit)
			           VALUES ($1, 'length', 'decimal', uuidv7()) RETURNING id)
			SELECT 1`, r.tenant)
		wantState(t, err, "23505", `A quantity named "length" already exists (global)`)
	})

	t.Run("a tenant's family in a global quantity, but not in another tenant's", func(t *testing.T) {
		family := r.d.id(t, "INSERT INTO public.unit_family (tenant, quantity, name) VALUES ($1, $2, 'Nautical length') RETURNING id",
			r.tenant, length)
		r.d.mustExec(t, "INSERT INTO public.unit (tenant, family, name, symbol, base_factor) VALUES ($1, $2, 'nautical mile', 'nmi', 1852)",
			r.tenant, family)

		err := r.d.exec(t, "INSERT INTO public.unit (tenant, family, name, symbol, base_factor) VALUES ($1, $2, 'cable', 'cbl', 185.2)",
			other, family)
		wantState(t, err, "23514", `Unit "cbl" can't be in another tenant's family`)
	})

	t.Run("a symbol means one unit within a quantity", func(t *testing.T) {
		family := r.d.id(t, "INSERT INTO public.unit_family (tenant, quantity, name) VALUES ($1, $2, 'Odd length') RETURNING id",
			r.tenant, length)
		err := r.d.exec(t, "INSERT INTO public.unit (tenant, family, name, symbol, base_factor) VALUES ($1, $2, 'odd metre', 'm', 2)",
			r.tenant, family)
		wantState(t, err, "23514", `Unit symbol "m" already means a different unit`)
		// The same unit under the same symbol is fine.
		r.d.mustExec(t, "INSERT INTO public.unit (tenant, family, name, symbol, base_factor) VALUES ($1, $2, 'metre', 'm', 1)",
			r.tenant, family)
	})

	t.Run("a quantity's base unit is checked at commit", func(t *testing.T) {
		err := r.d.inTx(t, func(tx pgx.Tx) error {
			ctx := context.Background()
			var quantity, family string
			if err := tx.QueryRow(ctx, `
				INSERT INTO public.quantity (tenant, name, datatype, base_unit)
				VALUES ($1, 'Thickness', 'decimal', uuidv7()) RETURNING id`, r.tenant).Scan(&quantity); err != nil {
				return err
			}
			if err := tx.QueryRow(ctx, `
				INSERT INTO public.unit_family (tenant, quantity, name) VALUES ($1, $2, 'Thickness') RETURNING id`,
				r.tenant, quantity).Scan(&family); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `
				INSERT INTO public.unit (id, tenant, family, name, symbol, base_factor)
				SELECT q.base_unit, $1, $2, 'thou', 'th', 0.0000254 FROM public.quantity q WHERE q.id = $3`,
				r.tenant, family, quantity)
			return err
		})
		wantState(t, err, "23514", "The base unit of Thickness (th) must have factor 1 and offset 0")
	})

	t.Run("an item's unit changes only within its quantity", func(t *testing.T) {
		class := r.class(t, "Cables", "")
		item := r.d.id(t, "INSERT INTO public.item (code, class, name, unit) VALUES (tenant.take_codes($1, 1), $2, 'Cable', $3) RETURNING id",
			r.tenant, class, r.unit(t, "Metric length", "m"))
		r.d.mustExec(t, "UPDATE public.item SET unit = $2 WHERE id = $1", item, r.unit(t, "Imperial length", "ft"))
		err := r.d.exec(t, "UPDATE public.item SET unit = $2 WHERE id = $1", item, r.unit(t, "Metric weight", "kg"))
		wantState(t, err, "23514", `The unit of "Cable" can only change to another unit of the same quantity`)
	})

	t.Run("the units' version moves on, for every tenant when global", func(t *testing.T) {
		before, otherBefore := r.version(t, "unit"), rules{d: r.d, tenant: other}.version(t, "unit")
		r.d.mustExec(t, "INSERT INTO public.tenant_quantity (tenant, quantity, available) VALUES ($1, $2, false)", r.tenant, length)
		if got := r.version(t, "unit"); got != before+1 {
			t.Errorf("version %d after a choice, want %d", got, before+1)
		}
		if got := (rules{d: r.d, tenant: other}).version(t, "unit"); got != otherBefore {
			t.Errorf("another tenant's version moved on: %d", got)
		}
		r.d.mustExec(t, "UPDATE public.unit_family SET name = name || '' WHERE tenant IS NULL")
		if got := (rules{d: r.d, tenant: other}).version(t, "unit"); got != otherBefore+1 {
			t.Errorf("another tenant's version %d after a global change, want %d", got, otherBefore+1)
		}
	})
}

func TestTakeCodes(t *testing.T) {
	r := newRules(t, "rules-codes")
	first := r.d.value(t, "SELECT tenant.take_codes($1, 3)", r.tenant)
	next := r.d.value(t, "SELECT tenant.take_codes($1, 1)", r.tenant)
	if first != int64(32768) || next != int64(32771) {
		t.Errorf("took %v, then %v; want 32768 and 32771", first, next)
	}
	if got := r.d.value(t, "SELECT util.code_text(32768)"); got != "1000" {
		t.Errorf("code_text(32768) = %v", got)
	}
}

// ---------------------------------------------------------------------------
// Trees, containers and deleting
// ---------------------------------------------------------------------------

func TestTreeRules(t *testing.T) {
	r := newRules(t, "rules-trees")
	tools := r.class(t, "Tools", "")
	drills := r.class(t, "Drills", tools)

	t.Run("no class below itself", func(t *testing.T) {
		err := r.d.exec(t, "UPDATE public.class SET parent = $2 WHERE id = $1", tools, drills)
		wantState(t, err, "23514", `Class "Tools" can't be moved below itself`)
	})

	t.Run("the tree's version moves on once per statement", func(t *testing.T) {
		before := r.version(t, "class")
		r.d.mustExec(t, "UPDATE public.class SET name = name || ' ' WHERE tenant = $1", r.tenant)
		if got := r.version(t, "class"); got != before+1 {
			t.Errorf("version %d after renaming two classes, want %d", got, before+1)
		}
	})

	// The parent keys are RESTRICT: a class with classes below it, or
	// items, can't go on its own (the delete functions say so first, with
	// names), but a whole subtree can go in one statement, as the key is
	// checked once the statement's rows are gone.
	t.Run("only an empty class, or a whole subtree, can be deleted", func(t *testing.T) {
		wantState(t, r.remove(t, "class", tools), "23001", "")
		saw := r.item(t, drills, "Saw")
		wantState(t, r.remove(t, "class", drills), "23001", "")
		r.d.mustExec(t, "DELETE FROM public.item WHERE id = $1", saw)
		r.d.mustExec(t, "DELETE FROM public.class WHERE id IN ($1, $2)", tools, drills)
		if n := r.d.value(t, "SELECT count(*) FROM public.class WHERE tenant = $1", r.tenant); n != int64(0) {
			t.Errorf("%v classes left after deleting the subtree", n)
		}
	})
}

func TestContainerRules(t *testing.T) {
	r := newRules(t, "rules-containers")
	shelves := r.class(t, "Shelves", "")
	box := r.class(t, "Boxes", "")
	r.d.mustExec(t, "UPDATE public.class SET container = true WHERE id = $1", box)

	t.Run("no items in a container class", func(t *testing.T) {
		err := r.d.exec(t, "INSERT INTO public.item (code, class, name) VALUES (tenant.take_codes($1, 1), $2, 'Box')", r.tenant, box)
		wantState(t, err, "23514", `Class "Boxes" is a container`)
	})

	t.Run("a class with items can't become a container", func(t *testing.T) {
		r.item(t, shelves, "Shelf")
		err := r.d.exec(t, "UPDATE public.class SET container = true WHERE id = $1", shelves)
		wantState(t, err, "23514", `it has 1 item(s), such as "Shelf"`)
	})

	t.Run("no stock in a container location", func(t *testing.T) {
		house := r.location(t, "House", "")
		garage := r.location(t, "Garage", house)
		drill := r.item(t, shelves, "Drill")
		row := r.stock(t, drill, garage, 1)

		err := r.d.exec(t, "UPDATE public.location SET container = true WHERE id = $1", garage)
		wantState(t, err, "23514", `Location "Garage" can't become a container: it has 1 stock row(s), such as Stock row`)

		r.d.mustExec(t, "UPDATE public.location SET container = true WHERE id = $1", house)
		err = r.d.exec(t, "UPDATE public.stock SET location = $2 WHERE id = $1", row, house)
		wantState(t, err, "23514", `Location "House" is a container`)
	})

	// Putting an item in a class locks the class for sharing until commit,
	// so making the class a container at the same time waits, and then sees
	// the item.
	t.Run("a new item and a new container at the same time", func(t *testing.T) {
		ctx := context.Background()
		tools := r.class(t, "Hand tools", "")
		first, err := r.d.dba.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer first.Rollback(ctx)
		if _, err := first.Exec(ctx,
			"INSERT INTO public.item (code, class, name) VALUES (tenant.take_codes($1, 1), $2, 'Hammer')", r.tenant, tools); err != nil {
			t.Fatal(err)
		}

		done := make(chan error, 1)
		go func() {
			done <- r.d.exec(t, "UPDATE public.class SET container = true WHERE id = $1", tools)
		}()
		select {
		case err := <-done:
			t.Fatalf("making the class a container didn't wait for the item: %v", err)
		case <-time.After(300 * time.Millisecond):
		}
		if err := first.Commit(ctx); err != nil {
			t.Fatal(err)
		}
		wantState(t, <-done, "23514", `it has 1 item(s), such as "Hammer"`)
	})
}

// ---------------------------------------------------------------------------
// Attributes and values
// ---------------------------------------------------------------------------

func TestValueRules(t *testing.T) {
	r := newRules(t, "rules-values")
	tools := r.class(t, "Tools", "")
	drills := r.class(t, "Drills", tools)
	pieces := r.attribute(t, "Pieces", "integer", "")
	serial := r.attribute(t, "Serial", "text", "")
	size := r.attribute(t, "Size", "choice", "")
	small := r.option(t, size, "Small")
	r.assign(t, tools, pieces, "item", false)
	r.assign(t, tools, serial, "stock", false)
	r.assign(t, tools, size, "item", false)
	drill := r.item(t, drills, "Drill")

	setValue := func(item, attribute, column string, value any) error {
		return r.d.exec(t, "INSERT INTO public.item_value (item, attribute, "+column+") VALUES ($1, $2, $3)", item, attribute, value)
	}

	t.Run("a value fits its datatype", func(t *testing.T) {
		wantState(t, setValue(drill, pieces, "number", 2.5), "23514", `The value for "Pieces" doesn't fit its datatype (integer)`)
		if err := setValue(drill, pieces, "number", 3); err != nil {
			t.Fatal(err)
		}
	})

	t.Run("a value is on the item or the stock row, as assigned", func(t *testing.T) {
		wantState(t, setValue(drill, serial, "text", "X1"), "23514", `has no attribute "Serial" with its values on the item`)
	})

	t.Run("options only for choice attributes", func(t *testing.T) {
		err := r.d.exec(t, "INSERT INTO public.attribute_option (attribute, name) VALUES ($1, 'Big')", pieces)
		wantState(t, err, "23514", `Attribute "Pieces" is not a choice attribute`)
	})

	t.Run("an attribute's datatype never changes", func(t *testing.T) {
		err := r.d.exec(t, "UPDATE public.attribute SET datatype = 'decimal' WHERE id = $1", pieces)
		wantState(t, err, "23514", `The datatype of attribute "Pieces" can't be changed`)
	})

	t.Run("an assignment can't be removed while values use it", func(t *testing.T) {
		err := r.d.exec(t, "DELETE FROM public.class_attribute WHERE class = $1 AND attribute = $2", tools, pieces)
		wantState(t, err, "23514", `1 item(s) would have values without a matching attribute, such as "Drill"`)
	})

	// Revised in the accessor review: a nearer assignment with the other
	// scope would leave the values on the wrong side.
	t.Run("a new assignment can't override the scope of values in use", func(t *testing.T) {
		err := r.d.exec(t, "INSERT INTO public.class_attribute (class, attribute, scope) VALUES ($1, $2, 'stock')", drills, pieces)
		wantState(t, err, "23514", `would have values without a matching attribute`)
		// The same scope is fine.
		r.assign(t, drills, pieces, "item", false)
	})

	t.Run("an item can't change to a class where its values don't apply", func(t *testing.T) {
		garden := r.class(t, "Garden", "")
		err := r.d.exec(t, "UPDATE public.item SET class = $2 WHERE id = $1", drill, garden)
		wantState(t, err, "23514", `Item "Drill" has values that don't apply in class "Garden": Pieces`)
	})

	t.Run("required values, checked at commit", func(t *testing.T) {
		saws := r.class(t, "Saws", "")
		blade := r.attribute(t, "Blade", "text", "")
		r.assign(t, saws, blade, "item", true)
		err := r.d.exec(t, "INSERT INTO public.item (code, class, name) VALUES (tenant.take_codes($1, 1), $2, 'Saw')", r.tenant, saws)
		wantState(t, err, "23514", `Item "Saw" is missing required attributes: Blade`)

		// Created, and given its value, in one transaction.
		var saw string
		if err := r.d.inTx(t, func(tx pgx.Tx) error {
			ctx := context.Background()
			if err := tx.QueryRow(ctx,
				"INSERT INTO public.item (code, class, name) VALUES (tenant.take_codes($1, 1), $2, 'Saw') RETURNING id",
				r.tenant, saws).Scan(&saw); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, "INSERT INTO public.item_value (item, attribute, text) VALUES ($1, $2, 'Wood')", saw, blade)
			return err
		}); err != nil {
			t.Fatal(err)
		}
		err = r.d.exec(t, "DELETE FROM public.item_value WHERE item = $1 AND attribute = $2", saw, blade)
		wantState(t, err, "23514", `The value for "Blade" on item "Saw" is required`)
	})

	t.Run("an option or attribute in use can't be deleted", func(t *testing.T) {
		chisel := r.item(t, tools, "Chisel")
		if err := setValue(chisel, size, "option", small); err != nil {
			t.Fatal(err)
		}
		wantState(t, r.remove(t, "attribute_option", small), "23001", "")
		wantState(t, r.remove(t, "attribute", pieces), "23001", "")
		// Deleting the item takes its values along, and then the option can go.
		r.d.mustExec(t, "DELETE FROM public.item WHERE id = $1", chisel)
		if err := r.remove(t, "attribute_option", small); err != nil {
			t.Fatal(err)
		}
	})
}

func TestStockRules(t *testing.T) {
	r := newRules(t, "rules-stock")
	class := r.class(t, "Things", "")
	screw := r.item(t, class, "Screw")
	cable := r.d.id(t, "INSERT INTO public.item (code, class, name, unit) VALUES (tenant.take_codes($1, 1), $2, 'Cable', $3) RETURNING id",
		r.tenant, class, r.unit(t, "Metric length", "m"))
	shelf := r.location(t, "Shelf", "")

	t.Run("counted items in whole numbers", func(t *testing.T) {
		err := r.d.exec(t, "INSERT INTO public.stock (code, item, location, amount) VALUES (tenant.take_codes($1, 1), $2, $3, 1.5)",
			r.tenant, screw, shelf)
		wantState(t, err, "23514", `The amount of "Screw" must be a whole number`)
		r.stock(t, cable, shelf, 2.5)
	})

	t.Run("an item with stock can't be deleted", func(t *testing.T) {
		r.stock(t, screw, shelf, 10)
		wantState(t, r.remove(t, "item", screw), "23001", "")
	})

	// A required value can't be removed from a stock row, but the row can
	// be deleted, taking its values along: the check at commit finds the
	// row gone and leaves it alone.
	t.Run("a stock row with a required value can be deleted", func(t *testing.T) {
		serial := r.attribute(t, "Serial", "text", "")
		r.assign(t, class, serial, "stock", true)
		var row string
		if err := r.d.inTx(t, func(tx pgx.Tx) error {
			ctx := context.Background()
			if err := tx.QueryRow(ctx,
				"INSERT INTO public.stock (code, item, location) VALUES (tenant.take_codes($1, 1), $2, $3) RETURNING id",
				r.tenant, screw, shelf).Scan(&row); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, "INSERT INTO public.stock_value (stock, attribute, text) VALUES ($1, $2, 'S1')", row, serial)
			return err
		}); err != nil {
			t.Fatal(err)
		}
		err := r.d.exec(t, "DELETE FROM public.stock_value WHERE stock = $1", row)
		wantState(t, err, "23514", `is required, so it can't be removed`)
		if err := r.remove(t, "stock", row); err != nil {
			t.Fatal(err)
		}
	})
}

func TestAttachmentRules(t *testing.T) {
	r := newRules(t, "rules-attachments")
	class := r.class(t, "Things", "")
	drill := r.item(t, class, "Drill")
	attach := func(owner, mediaType, title string) string {
		return r.d.id(t, `
			INSERT INTO public.attachment (item, media_type, hash, size, title)
			VALUES ($1, $2, repeat('ab', 32), 10, $3) RETURNING id`, owner, mediaType, title)
	}
	manual := attach(drill, "application/pdf", "Manual")
	photo := attach(drill, "image/jpeg", "Photo")

	t.Run("a photo is an image", func(t *testing.T) {
		err := r.d.exec(t, "UPDATE public.item SET photo = $2 WHERE id = $1", drill, manual)
		wantState(t, err, "23514", `A photo must be an image; "Manual" is application/pdf`)
		r.d.mustExec(t, "UPDATE public.item SET photo = $2 WHERE id = $1", drill, photo)
	})

	t.Run("a photo is one of the owner's own attachments", func(t *testing.T) {
		saw := r.item(t, class, "Saw")
		err := r.d.exec(t, "UPDATE public.item SET photo = $2 WHERE id = $1", saw, photo)
		wantState(t, err, "23503", "")
	})

	t.Run("deleting the photo's attachment clears the photo", func(t *testing.T) {
		if err := r.remove(t, "attachment", photo); err != nil {
			t.Fatal(err)
		}
		if got := r.d.value(t, "SELECT photo FROM public.item WHERE id = $1", drill); got != nil {
			t.Errorf("the photo is %v after its attachment was deleted", got)
		}
	})
}
