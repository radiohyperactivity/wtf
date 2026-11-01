# Changes to the apps – reminders

What the refactor ([database](2026-10-31-database-refactor.md), [accessors](2026-10-31-pl-pgsql-accessor-refactor.md), [API](2026-10-31-api-refactor.md)) means for the Flutter apps in `app/`. Collected as the decisions are taken; done after the API, when its new shape is known. The database starts over (database decision 6), so the apps only need to read the new names, never the old ones. The CLI changes with the API, in part 3.

## From database decision 2: scopes `item` and `stock`

- **The model:** `ClassAttribute.perUnit` (`lib/api/models.dart`) becomes a `scope` of `item` or `stock`, read from `"scope"` in place of `"per_unit"`. Everything that asks `perUnit` asks the scope instead: `lib/widgets/value_fields.dart`, `lib/screens/item_form.dart`, `stock_form.dart`, `search_screen.dart`, `class_screen.dart`.
- **Assigning an attribute** (`class_screen.dart`): the "Per unit" switch becomes a choice of **Item** or **Stock row** under "Values on", and `lib/api/client.dart` sends `scope`.
- **Words:** "per-unit values" and "(per unit)" become stock values and attributes: the stock form's section "Per-unit values", the search screen's "(per unit)" label and its hint "Per-unit attributes match when any stock row does", and the comments that say per unit.
- **History** (`lib/api/history_text.dart`): the table `value` is `item_value`, and an assignment's `per_unit` is `scope`.
- **Tests:** `test/fake_server.dart` and `test/app_test.dart` follow the new names.

## From database decision 3: a stock row's `amount`

- **The model:** the stock row's `quantity` (and the stock quantity class in `lib/api/models.dart`, with `quantityText`) becomes `amount`, read from `"amount"`; the item's stock total likewise.
- **Words:** the stock screen's field "Quantity" (`stock_screen.dart`) and the stock input's label "Quantity" (`lib/widgets/value_fields.dart`) become **Amount**; so do the move dialog's texts and the comments that speak of a stock quantity.
- **Not this:** "quantity" in the units sense (Length, Weight) stays: Admin → Units, the unit pickers, `Quantity` in the units model.
- **History:** a stock row's change shows `amount`.
- **Tests:** `test/fake_server.dart` and `test/app_test.dart` follow.

## From database decision 4: typed columns `text`, `number`, `date`, `boolean`, `option`

- **History** (`lib/api/history_text.dart`, `typed()` and the option look-ups near the top): a value row's columns are `text`, `number`, `date`, `boolean` and `option`, in place of `text_value`, `integer_value`, `float_value` and so on. An assignment's defaults are `default_text`, `default_number` and so on, in place of `text_default` …; `typed()` takes the prefix in place of its `suffix`.

## From database decision 8: one `attachment` table

- **History** (`lib/api/history_text.dart`, where it collects attachment titles and where it describes entries): the tables `item_attachment`, `stock_attachment`, `location_attachment` and `class_attachment` are one, `attachment`; which object it belongs to is in the row (`item`, `stock`, `location` or `class`).

## From database decision 15: the `deletion` table

- **History** (`lib/api/history_text.dart`, everywhere it reads `deleted`): a row's `deleted` is null when live and the id of the action that deleted it when deleted, in place of false and true; a delete or restore shows as a change of `deleted` from null to an id, or back.
- **The objects' own `deleted`** in the API's JSON is for part 3 to decide; the apps follow it.

## From database decision 24: the datatype `decimal`

- **The datatype `'float'` is `'decimal'`:** the datatype list in `lib/api/models.dart` (and `isNumber`), `lib/api/units.dart`, `lib/screens/attribute_screens.dart` and `search_screen.dart`, where they ask `'integer' || 'float'`; and wherever the datatype is shown by name.

## From database decision 25: sessions

- **Logging in:** the user chooses how long the session may sit idle, with "never" as a choice, and the app sends its own name ("WtF on Pixel 9"). The details are to be talked through when we get to the apps.
- **Me:** a list of the user's sessions (which client, since when, last used, from where), with a way to log one out.

## From database decision 35: an attribute's datatype never changes

- **The attribute form** (`lib/screens/attribute_screens.dart`): when editing, the datatype is shown, not offered as a choice, and is no longer sent (`if (datatype != current.datatype) 'datatype': …`). Picking a unit still sets the datatype, but only when creating.

## From accessor decision 8: history pages

- **The history screen** (`lib/screens/history_screen.dart`) asks for the entries older than the oldest it has (`before`), not by `offset`, and shows "Show older" while the page says `more`, without the count of changes left; the page model in `lib/api/models.dart` follows.

## From database decision 37 and accessor decision 18: actions

- **History entries** (`lib/api/history_text.dart`, `lib/api/models.dart`): each carries `action: {id, at, account}` in place of `transaction`, `happened_at` and `account`; entries are grouped into one sentence by the action's `id` (today by `transaction`, line 347), and the time and who are read from the action.

## From accessor decision 20: the problem type for 55000

- **`lib/api/client.dart`:** the constant `deleted = '/problems/deleted'` becomes `/problems/wrong-state`, and `intoDeleted` checks the type `/problems/restore-into-deleted` (API decision 14) and reads `place_key` and `with_parents` from its fields, in place of searching the hint.

## From accessor decision 24: a new password

- **The password form** (Me): a choice "Log out my other devices", sent with the new password; today the other sessions always end.
- **An admin setting or removing a user's password** (Admin → Accounts): a choice "Log the user out everywhere", sent as `end_sessions`, suggested when the password is removed; an admin's own password only through Me.

## From accessor decision 27: the units by version

- **`lib/api/client.dart`, `unitFamilies()`:** keeps the families as today, but asks again, with the version it has (`If-None-Match`), whenever it would use them, as for the class and location trees; a `304` keeps what it has.

## From accessor decision 28: units by id

- **The models** (`lib/api/models.dart`): an attribute's, item's and stock row's `unit`, and a `display`'s `unit`, are ids, looked up in `unitFamilies()` (decision 27) where today they are read as whole units; the screens and `lib/api/units.dart` take the looked-up unit.

## From API decisions 4 and 5: names, and the unit lists

- **The names** of API decision 4 everywhere the models read them (most already listed above, per database decision).
- **The unit families** (`lib/api/models.dart`, `lib/api/units.dart`): a unit in a family has no `family` or `quantity` of its own (found by where it sits); a quantity's `base_unit` is an id, looked up among its families' units.

## From API decision 7: `deleted`

- **Every model with `deleted`** (`lib/api/models.dart`): null, or `{action, at, account}`, in place of `true` or `false`; **the "Deleted" banner** (`DeletedBanner`, used by the class, item, stock and location screens) says by whom and when.
