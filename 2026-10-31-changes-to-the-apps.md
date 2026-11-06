# Changes to the apps – reminders

**Status: done (2026-11-04),** all of it, in `app/`; [APP.md](APP.md) decisions 72–83 describe the result.

What the refactor ([database](2026-10-31-database-refactor.md), [accessors](2026-10-31-pl-pgsql-accessor-refactor.md), [API](2026-10-31-api-refactor.md)) means for the Flutter apps in `app/`. Collected as the decisions are taken; done after the API, when its new shape is known. The database starts over (database decision 6), so the apps only need to read the new names, never the old ones. The CLI changes with the API, in part 3.

## From database decision 2: scopes `item` and `stock`

- **The model:** `ClassAttribute.perUnit` (`lib/api/models.dart`) becomes a `scope` of `item` or `stock`, read from `"scope"` in place of `"per_unit"`. Everything that asks `perUnit` asks the scope instead: `lib/widgets/value_fields.dart`, `lib/screens/item_form.dart`, `stock_form.dart`, `search_screen.dart`, `class_screen.dart`.
- **Assigning an attribute** (`class_screen.dart`): the "Per unit" switch becomes a choice of **Item** or **Stock row** under "Values on", and `lib/api/client.dart` sends `scope`.
- **Words:** "per-unit values" and "(per unit)" become stock values and attributes: the stock form's section "Per-unit values", the search screen's "(per unit)" label and its hint "Per-unit attributes match when any stock row does", and the comments that say per unit.
- **Tests:** `test/fake_server.dart` and `test/app_test.dart` follow the new names.

## From database decision 3: a stock row's `amount`

- **The model:** the stock row's `quantity` (and the stock quantity class in `lib/api/models.dart`, with `quantityText`) becomes `amount`, read from `"amount"`; the item's stock total likewise.
- **Words:** the stock screen's field "Quantity" (`stock_screen.dart`) and the stock input's label "Quantity" (`lib/widgets/value_fields.dart`) become **Amount**; so do the move dialog's texts and the comments that speak of a stock quantity.
- **Not this:** "quantity" in the units sense (Length, Weight) stays: Admin → Units, the unit pickers, `Quantity` in the units model.
- **Tests:** `test/fake_server.dart` and `test/app_test.dart` follow.

## From database decision 24: the datatype `decimal`

- **The datatype `'float'` is `'decimal'`:** the datatype list in `lib/api/models.dart` (and `isNumber`), `lib/api/units.dart`, `lib/screens/attribute_screens.dart` and `search_screen.dart`, where they ask `'integer' || 'float'`; and wherever the datatype is shown by name.

## From database decision 25: sessions

- **Logging in:** the user chooses how long the session may sit idle, with "never" as a choice, and the app sends its own name ("WtF on Pixel 9"). The details are to be talked through when we get to the apps.
- **Me:** a list of the user's sessions (which client, since when, last used, from where), with a way to log one out.

## From database decision 35: an attribute's datatype never changes

*Replaced by the plan of 2 November 2026 (below): attributes are part of their class, and a type never changes.*

- **The attribute form** (`lib/screens/attribute_screens.dart`): when editing, the datatype is shown, not offered as a choice, and is no longer sent (`if (datatype != current.datatype) 'datatype': …`). Picking a unit still sets the datatype, but only when creating.

## From accessor decision 24: a new password

- **The password form** (Me): a choice "Log out my other devices", sent with the new password; today the other sessions always end.
- **An admin setting or removing a user's password** (Admin → Accounts): a choice "Log the user out everywhere", sent as `end_sessions`, suggested when the password is removed; an admin's own password only through Me.

## From accessor decision 27: the units by version

*Gone with the units, by the plan of 2 November 2026 (below).*

- **`lib/api/client.dart`, `unitFamilies()`:** keeps the families as today, but asks again, with the version it has (`If-None-Match`), whenever it would use them, as for the class and location trees; a `304` keeps what it has.

## From accessor decision 28: units by id

*Gone with the units, by the plan of 2 November 2026 (below).*

- **The models** (`lib/api/models.dart`): an attribute's, item's and stock row's `unit`, and a `display`'s `unit`, are ids, looked up in `unitFamilies()` (decision 27) where today they are read as whole units; the screens and `lib/api/units.dart` take the looked-up unit.

## From API decisions 4 and 5: names, and the unit lists

*The unit lists are gone with the units, by the plan of 2 November 2026 (below); the names stay.*

- **The names** of API decision 4 everywhere the models read them (most already listed above, per database decision).
- **The unit families** (`lib/api/models.dart`, `lib/api/units.dart`): a unit in a family has no `family` or `quantity` of its own (found by where it sits); a quantity's `base_unit` is an id, looked up among its families' units.

## From the plan of 1 November 2026: no "mark as deleted", restore or history

[2026-11-01-dropping-deleted-and-history.md](2026-11-01-dropping-deleted-and-history.md). The API has no `deleted`, no restore routes and no history pages any more, so the apps lose what used them; the reminders above about history entries and `deleted` went with it.

- **What goes:** the history screen (`lib/screens/history_screen.dart`) and `lib/api/history_text.dart`, with the menu entries and buttons that open them; the restore widget (`lib/widgets/restore.dart`) and its uses; the "Deleted" banner (`DeletedBanner`) on the class, item, stock and location screens; `deleted` and `merged_into` in `lib/api/models.dart`; `intoDeleted` and the constant `deleted` in `lib/api/client.dart`.
- **Deleting asks first,** as it can't be undone: "Delete Drill? This can't be undone." on every delete, not only the recursive ones (CLI decision 67 does the same on a terminal).
- **A deleted thing's label:** scanning a code that answers 410 (`/problems/gone`) says "This label's item, stock row or location has been deleted", where a code never handed out (404) says that nothing has this label.
- **Moving and merging stock are two actions** (that plan's decision 6): a move never merges, so the stock screen gets a "Merge into…" action of its own, offering the item's other counted rows (`POST /stock/{id}/merge`). Where the rows differ, the plan of 2 November 2026 changes this (below).
- **Tests:** `test/fake_server.dart` and `test/app_test.dart` lose the history, restore and deleted cases, and gain the merge and the 410.

## From the plan of 2 November 2026: attributes in JSON, and no tenants

[2026-11-02-attributes-in-json.md](2026-11-02-attributes-in-json.md). The API's model of attributes, values, units, files and lists changed, and tenants are gone. The apps change with it, once, here.

- **Attributes are part of their class.** `GET /classes/{id}` lists them (`name`, `class`, `inherited`, `scope`, `type`, `required`, `unit`, `default`, `choices`, `media`, `order`), its own and inherited, in their order on screen.
  - **What goes:** Admin → Attributes and its screens (`lib/screens/attribute_screens.dart`), the options screens, and assigning an attribute to a class; `Attribute`, `Option` and `ClassAttribute` in `lib/api/models.dart` become one `Attribute` of the class.
  - **The class screen** (`class_screen.dart`) gets the class's attributes: adding one (name, type, item or stock row, unit, required, default, the choices, the media types), changing one it defines (required, default, unit, order, media types), renaming, removing, and adding, renaming and removing a choice. An inherited one says where it comes from, and is changed there.
  - **Every change says what it does first:** each takes `?dry_run=true`, which answers how many items and stock rows it would rewrite. The app shows that ("This rewrites 1,204 items.") and asks before sending it for real; a refusal (a required attribute without a default while items lack it, a choice still in use) is shown as it comes.
  - **A type never changes,** and neither does where the values live: the form offers neither when editing.
  - **Names** can't be those of the fixed fields (`name`, `class`, `unit`, `photo`, `amount`, `reference`, `serial`, …): the form says so (400).
- **Values are a JSON object by attribute name,** with `defaulted`, the names of those that follow the class's default.
  - **The value fields** (`lib/widgets/value_fields.dart`) read and write `values` by name; a value that follows the default shows that it does, and has a "Back to the default" action.
  - **Saving an item or a stock row is one PATCH,** its fields and its values together: `{"name": …, "values": {"Colour": "Blue", "Length": null}, "default": ["Size"]}`, null removing a value. The routes for one value (`PUT`/`DELETE …/values/{attribute}`) are gone.
  - **Creating** sends `values` by name; the attributes not given get their defaults.
- **Units are labels.** An attribute's `unit` and an item's `unit` are texts ("mm", "m"), shown after the numbers; nothing converts.
  - **What goes:** Admin → Units, the unit pickers and the menu next to number fields, `lib/api/units.dart`, `unitFamilies()` in `lib/api/client.dart`, the `display` of numbers and amounts, and Unit lock. An item's unit is a text field ("Unit of its stock"; empty: pieces).
- **Files are attachment attributes and photos.**
  - **What goes:** attachments of their own, with titles (`lib/widgets/attachments.dart` as it is), and the attachments and photos of locations and classes.
  - **An item and a stock row have a photo,** uploaded with `PUT …/photo` and shown from `GET …/photo`; `photo` in the answers is the file's hash, or null.
  - **An attachment attribute** is a value field of its own: upload (`PUT …/files/{attribute}`, refused when the attribute doesn't take that type), open or save (`GET …/files/{attribute}`, named after the attribute), and remove (a PATCH with the value null).
- **Stock rows have `reference` and `serial`,** optional texts, in the stock form and on the stock screen; the stock list searches them (`search`).
- **Merging asks what to keep:** where two rows differ (reference, serial, photo, a value), the merge is refused (422, naming the differences); the app shows both rows' values side by side, the user picks which to keep for each, and the app sends the merge again with `resolve`: `{"reference": "into", "serial": "from", "values": {"Colour": "from"}}`.
- **Lists page by key, without a total:** `GET /items` and `GET /stock` answer `{rows, more, next}`; the app asks for the next page with `after` (the `next` it got) as the list scrolls, and shows no count. `offset` is gone.
- **Search and filters:** search is as before for the user. Filters (`where`) name the attribute by name, not by id, and choices by their text.
- **No tenants:** a server is one installation. The login screen's server is a plain address, with no host to pick an inventory; nothing in the app knows about tenants.
- **Tests:** `test/fake_server.dart` and `test/app_test.dart` follow all of it: the class's attributes and their changes with dry runs, values by name in one patch, labels for units, photos and attachment attributes, reference and serial, merges with `resolve`, paging by key.
