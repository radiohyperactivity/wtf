# Locations and stock

The SQL is in [`db/repeatable/40_location.sql`](../db/repeatable/40_location.sql) and, for stock rows, [`db/repeatable/41_stock.sql`](../db/repeatable/41_stock.sql).

## Stock rows

A stock row is an item at a location, with an `amount` (in the base unit of the item's unit; null: not counted) and the values of its class's attributes with scope `stock`. `stock.create(p_item, p_location, p_amount, p_values)` makes one; `stock.patch` corrects its item, location, amount or photo.

`stock.move(p_stock, p_location, p_amount)` moves a row, or part of it, to another location; `p_amount` null moves the whole row, otherwise the row must be counted.

- **Merging:** if the destination holds exactly one live counted row of the same item, with exactly the same values, and the moved row has no attachments, the moved amount is added to that row. A whole row is then marked deleted, with `merged_into` that row.
- **Otherwise** a whole row changes location, and a part is split off into a new row at the destination, with a code of its own, copies of the values and of the attachments, and the copy of the photo as its photo.
- It returns the row at the destination.

## Deleting a subtree

Deleting marks locations deleted; they can be restored (`location.restore`). See [deleting.md](deleting.md). `location.delete` deletes one location, which must have no live sublocations or stock (409 otherwise). `location.delete_tree(p_location, p_force, p_dry_run)` (`DELETE /locations/{id}?recursive=true`) deletes a location and every live location below it in one action, deepest first:

- **Stock blocks it:** if there is live stock in any of them, nothing is deleted (23001, 409), and the message names the locations and their stock row counts (`Garage/Box (2 stock rows)`).
- **`p_force`** (`force=true`) deletes those stock rows too. The items themselves stay.
- **`p_dry_run`** deletes nothing; it only reports. Its route is a `GET`, `GET /locations/{id}/deletion?force=…`, so a server that doesn't know recursive deletes answers 404 rather than mistaking a preview for a delete. Unlike the delete, the preview reports stock without `force` instead of failing.
- **The result** is what was (or would be) deleted: `{locations: [{id, code, path}], stock: [{id, code, item: {id, code, name}, location, amount}]}`, locations deepest first.

## Containers

A location created or patched with `container: true` holds only other locations: no stock row can be at it, including by `stock.move` or by patching a stock row's location, and `location.patch` refuses to make a location with stock a container (23514, 422). `location.create` takes the flag, `location.patch` the key `container`, and `location.get` and the tree's nodes include it.

## Grids of compartments

`location.create(p_name, p_parent, p_container, p_columns, p_rows, p_confirm)` with `p_columns` and `p_rows` (in `POST /locations`: `"grid": {"columns": 8, "rows": 5}`, or `"grid": null` for none) also creates a compartment below the new location for every cell of the grid, in the same transaction:

- **Names:** like spreadsheet cells. Columns are letters (A … Z, then AA, AB, …), rows are numbers, and the top left is A1. So 8 × 5 gives A1 … H5, and B1 is right of A1, A2 below it.
- **The location becomes a container,** so stock goes into the compartments.
- **Nothing about the grid is stored:** the compartments are ordinary locations, each with its own label code. They can be renamed, moved or deleted like any other (e.g. when one compartment covers two cells).
- **Big grids need a confirmation:** a grid that creates more than 1000 locations (the compartments plus the location itself) needs `p_confirm` (`"confirm": true` in `grid`); without it, the call fails (400), so a typo can't flood the tree. Apps should ask the user before sending it.
