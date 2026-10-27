# Locations and stock

The SQL is in [`db/repeatable/50_location.sql`](../db/repeatable/50_location.sql).

## Deleting a subtree

Deleting marks locations deleted; they can be restored (`location_restore`). See [deleting.md](deleting.md). `location_delete` deletes one location, which must have no live sublocations or stock (409 otherwise). `location_delete_tree(p_id, p_force, p_dry_run)` (`DELETE /locations/{id}?recursive=true`) deletes a location and every live location below it in one transaction, deepest first:

- **Stock blocks it:** if there is live stock in any of them, nothing is deleted (23001, 409), and the message names the locations and their stock row counts (`Garage/Box (2 stock rows)`).
- **`p_force`** (`force=true`) deletes those stock rows too. The items themselves stay.
- **`p_dry_run`** deletes nothing; it only reports. Its route is a `GET`, `GET /locations/{id}/deletion?force=…`, so a server that doesn't know recursive deletes answers 404 rather than mistaking a preview for a delete. Unlike the delete, the preview reports stock without `force` instead of failing.
- **The result** is what was (or would be) deleted: `{locations: [{id, code, path}], stock: [{id, code, item: {id, code, name}, location, quantity}]}`, locations deepest first.

## Containers

A location created or patched with `container: true` holds only other locations: no stock row can be at it, including by `stock_move` or by patching a stock row's location, and `location_patch` refuses to make a location with stock a container (23514, 422). `location_create(p_name, p_parent, p_container)` takes the flag, `location_patch` the key `container`, and `location_get`, `location_list` and the tree nodes include it.

## Grids of compartments

`location_create(p_name, p_parent, p_container, p_grid)` with `p_grid` `{"columns": C, "rows": R}` (in `POST /locations`: `"grid": {"columns": 8, "rows": 5}`) also creates a compartment below the new location for every cell of the grid, in the same transaction:

- **Names:** like spreadsheet cells. Columns are letters (A … Z, then AA, AB, …), rows are numbers, and the top left is A1. So 8 × 5 gives A1 … H5, and B1 is right of A1, A2 below it.
- **The location becomes a container,** so stock goes into the compartments.
- **Nothing about the grid is stored:** the compartments are ordinary locations, each with its own label code. They can be renamed, moved or deleted like any other (e.g. when one compartment covers two cells).
- **Big grids need a confirmation:** a grid that creates more than 1000 locations (the compartments plus the location itself) needs `"confirm": true` in `grid`; without it, the call fails (400), so a typo can't flood the tree. Apps should ask the user before sending it.
