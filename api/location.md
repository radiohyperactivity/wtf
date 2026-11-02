# Locations and stock

The SQL is in [`db/repeatable/40_location.sql`](../db/repeatable/40_location.sql) and, for stock rows, [`db/repeatable/41_stock.sql`](../db/repeatable/41_stock.sql).

## Locations

`location.list(p_known_version)` is the location tree, flat, which `wtfd` nests (`GET /locations`, with `ETag` and `If-None-Match`); its version is `meta.location_version`. `location.get` is a location with its code and path. `location.create` and `location.patch` take `name`, `parent` and `container`; a move below itself is refused.

## Stock rows

A stock row is an item at a location, with:

- **`amount`**, in the item's unit (whole for pieces); null: present, but not counted; 0: none left, but this is where they belong;
- **`reference`** and **`serial`**, optional texts (an order number, a serial number); neither is unique;
- **`photo`**, the hash of its photo's file, or null;
- **`values`** and **`defaulted`**, for its item's class's attributes with scope `stock` ([attribute.md](attribute.md)).

`stock.create(p_item, p_location, p_amount, p_reference, p_serial, p_values)` makes one; `stock.patch` changes its item, location, amount, reference, serial, photo (null only) and values, in one transaction.

`stock.list(p_item, p_location, p_search, p_limit, p_after)` (`GET /stock`) is a page of stock rows by item name, paged by key as `item.list` is: of an item, in a location or below it, or with `p_search`, words that must each occur in the reference or the serial.

## Moving and merging

`stock.move(p_stock, p_location, p_amount)` moves a row, or part of it, to another location; `p_amount` null moves the whole row, otherwise the row must be counted. A whole row changes location and keeps its code; a part is split off into a new row at the destination, with a code of its own and everything else the row has: its reference, serial, photo and values. A move never merges into another row. It returns the row at the destination.

`stock.merge(p_stock, p_into, p_amount, p_resolve)` adds `p_amount` of a row (null: all of it) to another row, `p_into`, which may be at another location; it is the user's own action, not a side effect of moving.

- **Both rows** must be of the same item and counted, and not the same row.
- **Where they differ** (their reference, serial, photo, or a value), `p_resolve` says which row's to keep, for each difference:

  ```json
  {"reference": "into", "serial": "from", "photo": "into", "values": {"Colour": "from"}}
  ```

  `from` is `p_stock`'s, `into` is `p_into`'s. Without a resolution for every difference, the merge is refused (422, naming the differences), so that the client can ask the user. `p_into` takes what is resolved `from`.
- **All of it:** the row is deleted, and its label then answers 410 ([code.md](code.md)).
- **Part of it:** the row keeps the rest, as it was.
- It returns `p_into`.

## Deleting a subtree

Deleting removes a location for good; see [deleting.md](deleting.md). `location.delete` deletes one location, which must have no sublocations or stock (409 otherwise, saying which). `location.delete_tree(p_location, p_force, p_dry_run)` (`DELETE /locations/{id}?recursive=true`) deletes a location and every location below it in one action:

- **Stock blocks it:** if there is stock in any of them, nothing is deleted (23001, 409), and the message names the locations and their stock row counts (`Garage/Box (2 stock rows)`).
- **`p_force`** (`force=true`) deletes those stock rows too. The items themselves stay.
- **`p_dry_run`** deletes nothing; it only reports. Its route is a `GET`, `GET /locations/{id}/deletion?force=…`, so a server that doesn't know recursive deletes answers 404 rather than mistaking a preview for a delete. Unlike the delete, the preview reports stock without `force` instead of failing.
- **The result** is what was (or would be) deleted: `{locations: [{id, code, path}], stock: [{id, code, item: {id, code, name}, location, amount}]}`, locations deepest first.

## Containers

A location created or patched with `container: true` holds only other locations: no stock row can be at it, including by `stock.move` or by patching a stock row's location, and `location.patch` refuses to make a location with stock a container (23514, 422). Putting stock in a location locks the location row for sharing, so that it can't become a container meanwhile.

## Grids of compartments

`location.create(p_name, p_parent, p_container, p_columns, p_rows, p_confirm)` with `p_columns` and `p_rows` (in `POST /locations`: `"grid": {"columns": 8, "rows": 5}`, or `"grid": null` for none) also creates a compartment below the new location for every cell of the grid, in the same transaction:

- **Names:** like spreadsheet cells. Columns are letters (A … Z, then AA, AB, …), rows are numbers, and the top left is A1. So 8 × 5 gives A1 … H5, and B1 is right of A1, A2 below it.
- **The location becomes a container,** so stock goes into the compartments.
- **Nothing about the grid is stored:** the compartments are ordinary locations, each with its own label code. They can be renamed, moved or deleted like any other (e.g. when one compartment covers two cells).
- **Big grids need a confirmation:** a grid that creates more than 1000 locations (the compartments plus the location itself) needs `p_confirm` (`"confirm": true` in `grid`); without it, the call fails (400), so a typo can't flood the tree. Apps should ask the user before sending it.
