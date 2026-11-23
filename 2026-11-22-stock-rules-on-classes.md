# How stock is counted, set on the class – plan

**Status: planned and built on the night of 22 November 2026; not committed, for review.** Your idea, and your answers to three questions; everything else below is my judgement, marked **(mine)** where you haven't said. Steps 1–5 are done: the Go tests (integration included) and the app's 70 tests pass, and the web app builds. Nothing is rebuilt or installed, and the development database hasn't been touched: `wtfd schema` applies migration `0004` when you update it, and refuses if an item has a unit after all.

## What changes

Until now an item said what its stock is counted in (`item.unit`, a label; null for pieces), and any stock row could leave its amount empty ("present, not counted"). Now the **class** says how the stock of its items is counted, and its items follow it:

- **The counting rule** (your idea):
  - `none`: not counted. A stock row says "it is here", and has no amount.
  - `optional`: counted, and an amount may be left empty ("not counted yet"). What every item had until now.
  - `required`: counted; every stock row has an amount.
- **The unit** (your idea): what amounts are counted in, a label such as `m` or `kg`; null for pieces, whose amounts are whole. Nothing converts, as before. A class that doesn't count has no unit.

Your three answers:

1. **Everything in the database is in pieces today,** so moving over needs no choices: the migration checks that no item has a unit, and refuses otherwise.
2. **A class's unit can change while its items have counted stock, after confirming:** a dry run says how many stock rows would be relabelled (nothing converts: "2.5 m" becomes "2.5 cm"), and the change goes through when confirmed.
3. **Moving an item to a class with another unit, or a counting rule its stock doesn't meet, is refused,** saying why: change the stock, or the class, first.

## Decisions

### The database

1. **The rule is inherited down the class tree,** as attributes are (mine, from our talk): a class has a rule of its own, or its parent's; a top-level class without one of its own has the default, `optional` and pieces, which is what everything had until now. A new class inherits.
2. **Stored resolved on every class,** as attributes are, so that nothing walks up the tree to find it (mine; your preference for runtime cost): three columns on `public.class`:
   - `counting public.counting NOT NULL DEFAULT 'optional'`, a new enum (`none`, `optional`, `required`);
   - `unit public.name_text NULL` (null: pieces), with `CHECK (counting <> 'none' OR unit IS NULL)`;
   - `stock_from uuid NULL REFERENCES public.class (id)`: the class whose rule it is, itself when its own, null for the default. It says both whether the rule is the class's own and where an inherited one comes from, without a walk up the tree; as an attribute's definition says `class`.
   `class.rebuild`, which already makes a subtree's attributes again from the top down, does the rule in the same pass.
3. **`item.unit` is dropped** (migration `0004`). An item's unit is its class's.
4. **Stock rows are checked against their class's rule when written** (`stock.check_amount`, now given the class): no amount when `none`; an amount when `required`; whole in pieces; never below 0.
5. **Changing a class's rule checks every stock row below it** (`class.check_stock`): a row that doesn't fit the new rule (an amount where nothing is counted, none where one is required, a part of a piece) refuses the change, with how many and one of them, as a new required attribute does. Changing the unit itself is allowed, and the answer says how many rows with an amount were relabelled (`relabelled`); a dry run says it without changing anything (your answer 2).
6. **Moving an item to another class** (`item.patch` with `class`) is refused when the new class's unit differs and any of its stock rows has an amount, or when a row doesn't fit the new counting rule (your answer 3). With the same unit, or only uncounted stock, it moves.
7. **A container class has a rule too,** for the classes below it to inherit, though it holds no items itself (mine).

### The API

Within `/api/v1`, changed in place, as in November: nothing is released, and every client is rebuilt with it. The revision stays 1 until 1.0.0 (your decision of tonight).

8. **A class's rule has routes of its own** (mine), like its attributes, with a dry run:
   - `PUT /classes/{id}/stock` with `{counting, unit}` gives the class a rule of its own (both required; `unit` null for pieces, and null when `counting` is `none`);
   - `DELETE /classes/{id}/stock` makes it inherit again;
   - both take `?dry_run=true`, and answer as an attribute change does, `{class, items, stock, dry_run}`, with `relabelled`: how many stock rows with an amount got another unit.
   Not a field of `PATCH /classes/{id}` (mine): that patch has no dry run, and the rule's change reaches every stock row below, as an attribute's does.
9. **A class's answer has its rule:** `GET /classes/{id}` (and every answer that shows a class in full) has `stock: {counting, unit, from}`, `from` being the class whose rule it is (its own id, an ancestor's, or null for the default). The class tree (`GET /classes`) doesn't (mine): it stays small, and the apps read the class in full where they need its rule.
10. **Items:** `POST /items` and `PATCH /items/{id}` no longer take `unit` (an unknown field, refused). An item's answers keep `unit`, now its class's, and gain `counting`, so that every client showing an amount has what it needs without asking for the class (mine: fewer changes in the clients, and no extra request).
11. **`POST /classes` doesn't take a rule** (mine): a new class inherits, and gets one of its own with `PUT …/stock`. The apps' New class form stays as it is; the rule is set on the class's screen.

### Model files

12. **Model files are of version 3,** with a class's own rule as `stock: {counting, unit}` (left out when it inherits). Version 2 files are still read: they have no rules, as units were the items' (mine).

### The CLI

13. **`wtf item add` and `wtf item edit` lose `--unit` and `--no-unit`;** the interactive edit form loses its unit field.
14. **`wtf class stock <class> --counting none|optional|required [--unit U]`** gives a class its own rule, and `wtf class stock <class> --inherit` makes it inherit (mine). It does a dry run first, and when that relabels counted stock, asks before going on (on a terminal), or needs `--yes` (otherwise); `--dry-run` only says what it would do. `wtf class get` shows the rule, and where it comes from.

### The apps

15. **The new-item and edit-item forms lose "Unit of its stock",** and the session's memory of units per class (decision 94) goes with it.
16. **Amounts follow the class's rule** on the new-item form's Stock section and on the stock form: no Amount field when nothing is counted, "Amount *" when one is required, the unit after it.
17. **The class's screen shows its rule,** "Stock: counted, optional · m" with where it comes from ("inherited from Tools"), and admins change it there: inherit, or a rule of its own (not counted, counted optional, counted required) with a unit. A dry run first; when it would relabel counted stock, the app says how many rows and asks before saving.

### Docs and tests

18. API.md, api/class.md, api/item.md, WTFD.md, the OpenAPI description, the CLI's docs and APP.md say so; the integration tests cover the rule, its inheritance, the refusals and the relabelling; the app's tests the forms.

## Order of work

1. Migration `0004` and the SQL (decisions 1–7, 12).
2. `wtfd`'s routes, the OpenAPI description, the integration tests (8–11).
3. The CLI (13–14).
4. The app (15–17).
5. The docs (18), and this plan's status.

## What I decided while doing it

For review; each is easy to change.

19. **Moving a class to another parent** (`PATCH /classes/{id}` with `parent`) is checked like a change of its rule, when it inherits one: refused when a stock row below doesn't fit the rule it would inherit, and when counted stock would get another unit, saying how many rows and to give the class a rule of its own first. The plan didn't cover it; refusing follows your answer 3 for items, since a move has no dry run to ask with.
20. **A stock row given to an item of another class** (`PATCH /stock/{id}` with `item`) keeps an amount only when the change gives it too, if the new class counts in another unit; otherwise refused ("nothing converts; give its amount too"). The same reasoning, for a rarer case.
21. **Model files:** a class that is there already must have the file's rule, its own or the one it inherits, or the import is refused (409), as for an attribute that differs; a class that is added gets the file's rule as its own, or inherits. An export gives the top class its rule also when inherited (not the default), as it gives it its inherited attributes, and the classes below only their own. Version 2 files are read as version 3 without rules; `seed/models/mcu.json` stays at version 2, which still reads.
22. **The class tree (`GET /classes`) has no rule** (decision 9 above): the app reads the class itself where it needs it, on the class screen and in the new-item form, which loads the class anyway for its attributes.
23. **Unit text:** trimmed, and empty is pieces, as an item's unit was. `none` with a unit is refused (400); an unknown counting (`lots`) too.
24. **What "relabelled" counts:** stock rows with an amount, of items of the class and of the classes below it, whose unit is another one after the change. Rows without an amount aren't counted: nothing is relabelled for them.
25. **Error statuses** follow what is there: a rule the stock doesn't fit, a move that would relabel, and an item moved where its stock doesn't fit are 422 (not allowed); a malformed rule is 400; a model file's class with another rule is 409, as a different attribute is.
26. **The CLI:** the command is `wtf class stock` (a verb of `class`, beside `set` and `edit`, rather than flags of `class set`, which has no dry run); its words in `class get` are `counted, optional, in m (from Tools)`. Adding `Stock:` to a class's fields moved its other fields one column right, which two tests looked for. `item add`'s offer of stock is still a request of its own, as before; the app's single request (decision 108) isn't used there yet.
27. **The app:**
    - The rule is said under **Add stock** ("Its class: counted, the amount optional · m."), not under the name, where it was in the way; the item's screen has it as **Stock**, replacing "Counted in".
    - Lists say **"not counted"** for the stock of a class that doesn't count, where "uncounted" would suggest a count is missing.
    - The rule is changed in a **dialog from the class's screen**, not on the class's edit form: that form is name, parent and container, saved with `PATCH`, while the rule has its own route and dry run (decision 8). The New class form stays as it is: a new class inherits (decision 11).
    - The session no longer remembers units (decision 94's unit is crossed out in APP.md).
28. **Tests added:** `TestStockRules` in the API's integration tests (the default, a rule of its own and its inheritance, an item's rule in its answers, `unit` refused on items, a dry run and a real change of unit with `relabelled`, the refusals, moving a class and an item, a stock row given to another item, `required` and `none`, inheriting again, and model files); the app test "a class says how its stock is counted, and the forms follow".
