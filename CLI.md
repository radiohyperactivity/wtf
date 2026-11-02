# wtf – the command-line client

`wtf` is a command-line client for the WtF REST API (`wtfd serve`). It is a Go program in the same module (`cmd/wtf`, with the code in `internal/cli`, `internal/client` and `internal/prompt`), built on the standard library plus `golang.org/x/term` for the terminal.

```sh
go build -o wtf ./cmd/wtf
wtf login --server http://localhost:8080 --email anna@example.com
wtf location add Garage
wtf location add "Shelf 2" --parent Garage
wtf class attribute add Tools Voltage --type decimal --unit V
wtf item add "Cordless drill" --class Tools --voltage 18
wtf stock add "Cordless drill" "Garage/Shelf 2" 1
wtf find drill
wtf item add            # asks for everything, with Tab completion
```

## Design

- **Commands are `noun verb`:** `wtf item list`, `wtf stock move …`, `wtf location tree`. A few shortcuts have no noun: `login`, `logout`, `whoami`, `password`, `find` and `code`.
  - `wtf help` lists everything, `wtf <noun>` lists its verbs, and `wtf <noun> <verb> -h` shows the flags.
  - Flags may come before, between or after the arguments. `--` ends the flags.
- **References:** wherever an object is expected, it can be named in several ways (details below). An ambiguous name is an error that lists the candidates.
- **Output:**
  - **Text:** readable text on stdout by default; notes, paging hints and errors go to stderr.
  - **JSON:** `--json` prints the API's JSON instead, for scripts and `jq`.
  - **Exit codes:** 0 for success, 1 for an error, 2 for wrong usage.
- **Configuration:**
  - **File:** `wtf login` stores the server and the token in `wtf/config.json` in the user's config directory, with mode 600. That is `~/.config` on Linux, `%AppData%` on Windows and `~/Library/Application Support` on macOS.
  - **Profiles:** named profiles (`--profile dev`) cover several servers. `wtf profile list|use|delete` manages them.
  - **Environment:** `WTF_PROFILE`, `WTF_SERVER` and `WTF_TOKEN` override the file, and `WTF_CONFIG` points to another file.
- **Passwords:**
  - **Login:** `wtf login` prompts without echo, or reads `WTF_PASSWORD` in scripts.
  - **Other prompts:** `wtf password` and `wtf account add|set --password` prompt the same way.
  - **Scripts:** when stdin is not a terminal, prompts read a line from stdin, so passwords can be piped in. Passwords are never taken as command-line arguments.
- **Attribute values are flags of their own** (decision 70): `--colour Blue` sets "Colour", `--no-colour` removes it, and `--default colour` puts it back to the class's default. Letter case is ignored and a hyphen stands for a space (`--supply-voltage 3.3` is "Supply voltage"). An attribute named like one of the command's own flags is set with `--value NAME=VALUE`.
- **Units are labels:** an attribute's or item's unit says what its numbers are in. A number may carry it (`12 mm` for a length in mm), but nothing converts: another unit is refused.
- **Dates:** `YYYY-MM-DD`, `today`, `yesterday`, `tomorrow`, or relative to today: `+3` or `+3d` (days), `-2w` (weeks), `+1m` (months), `-1y` (years). A month step stops at the end of a shorter month (31 January `+1m` is 28 February).
- **Interactive prompts:** on a terminal, `wtf` asks for whatever a command is missing, with Tab completion and a picker (see below).
- **Shell completion:** `wtf completion bash|zsh|powershell` prints the code for Tab completion of commands, flags and objects.
- **Long lists** show their first page, and say when more follow; `--all` shows every row, through a pager on a terminal.

### References

| Object | Named by |
|--------|----------|
| location | id, label code, or path: `Shelf 2`, `Garage/Shelf 2` (matching by its end; ambiguous paths are an error with suggestions) |
| class | id or path: `Screws`, `Hardware/Screws` |
| item | id, label code (of the item or of one of its stock rows), or exact name (any case) |
| stock row | id, label code, `ITEM@LOCATION` (`"Drill@Garage/Shelf 2"`), or an item that has exactly one stock row |
| attribute | its name, after its class: `wtf class attribute set Screws Length …`; letter case is ignored and a hyphen stands for a space |
| choice | its text, after its class and attribute |
| item or stock row, for files | a label code (of either), `ITEM@LOCATION` for a stock row, or an item's name |
| account | id or email |

### Commands

| Command | API |
|---------|-----|
| `wtf login [--server URL] [--email E] [--stay DURATION\|forever]`, `wtf logout`, `wtf whoami`, `wtf password [--log-out-others \| --keep-others]` | `/login`, `/logout`, `/me`, `/me/password` |
| `wtf sessions list` / `logout <session id> \| --others` | `/me/sessions` |
| `wtf profile list` / `use <name>` / `delete <name>` | (local configuration) |
| `wtf find <words…> [--class C] [--where CONDITION]…` | `GET /items?search=&where=`, plus each item's stock locations |
| `wtf code <code>` | `/codes/{code}` |
| `wtf item list [--class C] [--search S] [--where CONDITION]… [--limit N] [--all]` / `get` / `add <name> --class C [--unit U] [--<attribute> VALUE]… [--edit]` / `set [--name N] [--class C] [--unit U \| --no-unit] [--no-photo] [--<attribute> VALUE] [--no-<attribute>] [--default ATTRIBUTE]…` / `edit` / `delete` | `/items` |
| `wtf stock list [--item I] [--location L] [--search S] [--limit N] [--all]` / `get` / `add <item> <location> [amount] [--reference R] [--serial S] [--<attribute> VALUE]…` / `move <stock> <location> [amount]` / `merge <stock> <into> [amount] [--keep FIELD=from\|into]…` / `set [--amount A\|none] [--location L] [--item I] [--reference R \| --no-reference] [--serial S \| --no-serial] [--no-photo] [--<attribute> VALUE] …` / `edit` / `delete` | `/stock` |
| `wtf location tree` / `get` / `add <name or path> [--parent P] [--create-parents] [--container \| --grid COLUMNSxROWS] [--edit]` / `set [--name N] [--parent P\|none] [--container yes\|no]` / `edit` / `delete [--recursive [--force]] [--yes] [--verbose]` | `/locations` |
| `wtf class tree` / `get` / `add` / `set` / `edit` / `delete [--recursive [--force]] [--yes] [--verbose]` | `/classes` |
| `wtf class attribute add <class> <name> --type T [--stock] [--unit U] [--required] [--default V] [--choices A,B,C] [--media TYPES] [--order N] [--dry-run]` / `set <class> <attribute> [--required yes\|no] [--default V \| --no-default] [--unit U \| --no-unit] [--media TYPES \| --no-media] [--order N] [--dry-run]` / `rename <class> <attribute> <new name> [--dry-run]` / `remove <class> <attribute> [--dry-run] [--yes]` | `/classes/{id}/attributes` |
| `wtf class choice add <class> <attribute> <choice>…` / `rename <class> <attribute> <choice> <new>` / `remove <class> <attribute> <choice>`, each `[--dry-run]` | `/classes/{id}/attributes/{attribute}/choices` |
| `wtf file put <item or stock row> <attribute\|photo> <file>` / `get <item or stock row> <attribute\|photo> [file\|-] [--force]` | `/items/{id}/photo`, `/items/{id}/files/{attribute}`, and the same for `/stock` |
| `wtf model import <file> [--parent CLASS] [--dry-run]` / `export <class> [-o FILE] [--force]` | `/model/import`, `/classes/{id}/model` |
| `wtf account list` / `get` / `add <email> [--password] [--role R] [--edit]` / `set [--email E] [--password\|--no-password [--log-out\|--keep-sessions]] [--role R]` / `edit` / `delete` | `/accounts` |

## Interactive use

### Prompts

When stdin and stderr are a terminal, `wtf` asks for missing arguments instead of failing: `wtf item add` asks for the name, the class, and then the attribute values. Elsewhere (scripts, pipes) a missing argument is a usage error, as before.

- **What is asked:**
  - missing required arguments and flags (`--class` of `item add`, `--type` of `class attribute add`, …);
  - required attribute values that have no value or default, even when the command line was otherwise complete.
- **What is offered:** once `wtf` has asked for something, the session counts as interactive, and optional data is offered too. Enter skips it.
  - `item add`: the unit, then every attribute of the class, required ones first, with defaults shown as `Colour [red]`.
  - `stock add`: the amount (Enter: uncounted) and the class's stock attributes.
  - `stock move`, `stock merge`: the amount (Enter: all of it).
  - Files are uploaded with `wtf file put`, and never asked for.
- **Stock for a new item:** after `item add` (not with `--edit`), `wtf` asks once `Add stock for M3? [y/N]` on every terminal, also when the command line was complete. Yes asks for a location, an amount and the stock attributes' values, and adds that one stock row.
- **Bad values:** a value that doesn't parse (`3 kg` for a length in mm) is reported, and the prompt asks again.
- **Cancelling:** Ctrl-C, or Ctrl-D on an empty line, cancels the command without changing anything (exit code 130).

| Key | In a prompt |
|-----|-------------|
| Tab | complete: to the single match, or as far as all matches agree |
| Tab Tab | open the picker |
| ← → Home End, Ctrl-A Ctrl-E | move |
| Backspace, Delete, Ctrl-U, Ctrl-K, Ctrl-W | delete back, forward, to the start, to the end, a word |
| Enter | accept |

The picker lists the candidates under the prompt: whole paths for locations and classes, a choice's choices, yes and no, and so on. Typing filters the list (by substring, ignoring case), ↑ ↓ PgUp PgDn move, Enter picks, Esc returns to the prompt.

### Shell completion

```sh
eval "$(wtf completion bash)"                               # ~/.bashrc
source <(wtf completion zsh)                                # ~/.zshrc, after compinit
wtf completion powershell | Out-String | Invoke-Expression  # $PROFILE
```

Tab then completes commands, verbs, flags, and objects from the server, such as locations (`Garage/` → `Garage/Shelf 1`, `Garage/Shelf 2`), items, stock as `ITEM@LOCATION`, a class's attributes and choices, the files of an item (`photo` and its attachment attributes), profiles and file names.

### Lists

`find`, `item list` and `stock list` show one page (`--limit`, 100 by default), and say on stderr when more rows follow. With `--all` they show every row:
- **On a terminal:** through a pager that fetches pages only as needed. Space shows the next screen, Enter the next line, and q quits.
- **Piped:** all rows at once.

`--json` prints the API's page, or with `--all` every row in one answer, `{rows, more: false}`. Lists have no total (decision 74).

## Tests

- **Unit tests:**
  - `internal/cli` covers code normalisation, number and date parsing, attribute flags and conditions, path lookup and completion, flag parsing, shell word splitting and quoting, and the config file.
  - `internal/prompt` covers key decoding, line editing, Tab and the picker, with scripted keys.
- **Integration tests:** they run the client against the real API handler and the test database. See README.md, "Tests".
  - `TestCLI` works as the first account and as a second, read-only account.
  - `TestCLIInteractive` covers prompts, shell completion and paging, with scripted keys on a fake terminal.

## Decisions made while building

These are decisions I made without you, recorded for review.

### References

1. **Names before codes.** For locations and items, a unique exact name wins. Only if no name matches is the text tried as a label code. Any 4–7 characters of the Crockford alphabet could be a code (`Tool` reads as `T001`), so this order keeps names working. Stock rows have no names, so codes come first there.
2. **Paths match by their end, and ambiguity is an error** (changed after review). `Shelf 2` and `Garage/Shelf 2` match wherever that path ends. There is no marker for "from the root" and no rule that picks one match over another. When a path matches several classes or locations, the command stops, and lists each match with the shortest path that names it uniquely, or else its label code or id:
   ```
   wtf: location "Shelf 2" is ambiguous. Name one of them like this:
     1A7K                   for Garage/Shelf 2
     House/Garage/Shelf 2   for House/Garage/Shelf 2
   ```
   - **On a terminal, `wtf` asks instead** (added after review). The matches appear in the picker, sorted by path (`Which class "STM8"?`), where ↑ ↓ and typing choose, Enter takes one, and Esc cancels the command. The same goes for items with the same name and for an item's stock rows. Scripts and pipes get the error above.
   - **No `/` in names:** the server rejects `/` in class and location names (migration 0008), so a path always means one thing. Before, a root class named `MCU/AVR` and the class AVR under MCU were indistinguishable, and `class delete MCU/AVR` silently picked one.
   - **No leading `/`:** a path starting with `/` matches nothing, and the error says that paths don't start with `/`. It used to mean "from the root", but Git Bash rewrites such arguments into Windows paths (`/Garage` arrives as `C:/Program Files/Git/Garage`).
3. **Exact item names only** (confirmed in review). Items are found by exact name, ignoring case, using the search endpoint. When nothing matches, up to 10 partial matches are suggested, but none is picked automatically (think `item delete`).
4. **Extra stock forms.** Besides id and code, a stock row can be named as `ITEM@LOCATION`, or by an item that has exactly one stock row. This makes `wtf stock move Drill Garage` work.
5. **Attachments by id only.** The API has no way to find an attachment other than through its object. `attachment list TYPE REF` shows the ids.
6. **A target type for attachments.** `attachment add` takes `item|stock|location|class` explicitly, because the four kinds of reference overlap.

### Input

7. **Any unit of the quantity.** Units are accepted from the attribute's quantity, not only from its unit's family. So `--value Length=1in` works for a metric attribute, and the value is shown in the family's units.
8. **ASCII spellings.** `u` stands for `µ` (`um`, `uF`), `ohm` for `Ω` (`kohm`), and `deg` for `°` (`degC`). Case is ignored only when that is unique, so `mohm` is mΩ and `Mohm` is MΩ, while `mω` is ambiguous.
9. **Exact arithmetic.** The conversion uses exact fractions (`math/big`). Results that aren't finite decimals, such as °F, are sent with 30 decimal places.
10. **Other datatypes.**
    - **Booleans:** yes/no/true/false/y/n/1/0/on/off.
    - **Dates:** `YYYY-MM-DD`, `today`, `yesterday`, `tomorrow` and `±N[d|w|m|y]` (extended after review), checked in the client.
    - **Choices:** passed by name, and the API matches them ignoring case.
11. **Values on the command line.** `value-set` joins its remaining arguments with spaces, so both `2.5 cm` and `2.5cm` work. `item add` and `stock add` take repeatable `--value ATTRIBUTE=VALUE`.
12. **Negative numbers are arguments.** `-40` and `-5°C` are arguments, not flags, unless they follow a flag that takes a value.
13. **`class assign` replaces the assignment.** It is a PUT, so flags left out are reset: no default, not per-unit, not required.
14. **No delete confirmation.** Deletes don't ask first. The API refuses to delete anything still in use.

### Output

15. **Paging** (changed after review). Lists show all rows: through the built-in pager on a terminal, or all at once when piped. `--limit` or `--offset` asks for one page, with a hint for the next.
16. **What `--json` prints.** It prints the API's response unchanged in content, but indented. Exceptions:
    - `find --json` prints the search page without the extra per-item requests;
    - `attachment list --json` prints the object's `attachments` array;
    - lists without `--limit`/`--offset` print one envelope with all rows, whose `limit` is the number of rows.
17. **History was shown raw** (history went on 1 November 2026, decision 66).

### Configuration and sessions

18. **Login makes the profile current.** Its email is remembered for the next login. `logout` also clears the token when the session had already expired.
19. **Profile commands.** `profile list|use|delete` were added for managing profiles, and `WTF_CONFIG` for tests.
20. **Safe config writes.** The config file is written to a temporary file and renamed. On Windows, the mode 600 means little; the file relies on the user's profile directory being private.
21. **Long timeout.** The HTTP timeout is 15 minutes, for large uploads.
22. **Test hook.** `cli.Transport` let the integration test reach the in-process server under the tenant's hostname. It was removed with the tenants (decision 48).

### Settled after review

23. **Plain numbers follow the unit group** (changed after review; superseded by decision 48). A plain number meant the quantity's base unit, so for a Celsius attribute `20` meant 20 K. Now it means the group's base unit if the group has it, else the group's only unit, else a unit is required. The display unit couldn't be used, because it changes with the value.
24. **API error messages** are left as they are until they turn out to be a problem. Two kinds could be friendlier on the server side:
    - "Still in use" passes PostgreSQL's foreign-key message through, with UUIDs.
    - Some rule violations name attributes by id ("Attribute 8774… is not a per-kind attribute…"), and the word "per-kind" doesn't match `per_unit` anywhere else.
25. **The dev tenant after testing.** I exercised the client against the Development Tenant and deleted everything again; `wtfd gc` removed the one test file. What remains:
    - label codes 1000–1009, which were used up (1007–1009 by the completion test).

    The tests used a config file and cache in my scratch directory, not your real ones.

### Prompts, completion and paging

These follow your answers: all attributes offered, a picker on Tab Tab, bash, zsh and PowerShell, cached trees, all pages when piped, and our own pager and line editor on `x/term`.

26. **When prompts appear.** Only when stdin and stderr are both a terminal. Prompts and the picker draw on stderr, so `--json` output on stdout stays clean.
27. **Optional data is offered only in an interactive session.** Optional data (unit, optional attributes, quantity) is offered once `wtf` has asked for something. When the command line was complete, only required attribute values without a value or default are asked for, so scripts typed by hand don't turn into questionnaires.
28. **Prompts don't check references as you type.** A wrong name in a prompt (`Location: Nowhere`) fails the command the same way as on the command line. Attribute values are checked, and asked for again.
29. **Tab in a prompt.** Tab completes by prefix, ignoring case, and otherwise to a single candidate that contains the text (`scr` → `Hardware/Screws`). A second Tab opens the picker, which shows up to 10 rows and filters by substring. For items, the picker searches the server on each key press.
30. **Shell protocol.** The scripts call a hidden `wtf __complete SHELL …`, which prints one candidate per line, or `:files` for the shell's own file name completion.
    - **bash:** gets the line up to the cursor and quotes the candidates itself, matching an opened `"` or `'`. It copes with bash splitting words at `=` and `:`, as in `--value Colour=red`.
    - **zsh and PowerShell:** get the words, and quote the candidates themselves.
31. **Paths, the same in every shell** (changed after review). Paths complete one segment at a time from the roots (`Garage/` → its children). A bare name below the root (`Shelf 2`) still works when typed, but isn't offered. PowerShell puts quotes around a path with spaces (`'Garage/Shelf 2/'`), and completing on from there works.
32. **Matching, the same in every shell.** Matches ignore case, plus a single substring match (`drill` → `Cordless drill`). zsh itself matches case-sensitively unless your `matcher-list` says otherwise.
33. **Cache.** The class and location trees are kept in the user's cache directory per server (`$WTF_CACHE_DIR` overrides it) and revalidated with their version on every use. That also speeds up ordinary commands. Attributes, unit families, quantities and units are cached for a minute, only while completing. Adding, changing or deleting an attribute or option drops the cached attributes at once, so a new one completes straight away. A change to a class or location likewise drops the run's copy of that tree. Quantities, unit families and units can't be changed through the API. A database recreated from scratch could reuse a tree version and show a stale tree; deleting the cache directory fixes that.
34. **Pager.**
    - **Fetching:** it fetches 100 rows at a time (20 for `find`, which makes one request per item).
    - **Columns:** they are aligned within each batch of 100, so widths may shift between batches.
    - **When:** it needs stdin and stdout to be a terminal.
35. **Windows terminals.** VT processing is switched on for the console, so the prompts work in Windows Terminal, the VS Code terminal and PowerShell. Git Bash's mintty only counts as a terminal when it uses ConPTY. Without it, `wtf` sees pipes, so it neither prompts nor pages, and behaves as in a script.
36. **Tab in PowerShell works as in bash** (changed after review). PSReadLine's default Tab cycles through the matches. The PowerShell script therefore binds Tab to PSReadLine's `Complete` when the command at the cursor is `wtf`: it completes as far as all matches agree, and a second Tab lists them. For any other command, Tab does whatever it did before. Loading the script twice is harmless. This needs PSReadLine, which PowerShell 5.1 and 7 load by default.
    - **Trailing space:** a complete term is inserted with a space after it, as in bash, so the next argument can follow at once. `Garage/` and `Colour=` are inserted without one.
    - **Bare `-` and `--`:** PowerShell never asks a native completer about these, because it takes them for its own parameter syntax. The script therefore wraps `TabExpansion2`, the function all completion goes through. Only when PowerShell found nothing, the command is `wtf` and the word is `-` or `--` does it fill in wtf's flags. Other commands are unaffected.
37. **Not done:** completion of attachment ids, completion after `wtf help`, and fish.

### Creating by path

38. **`class add` and `location add` take a path** (added after review). `wtf class add MCU/AVR/Old` creates Old under MCU/AVR.
    - **Finding the parent:** the parent path is resolved like any reference, by its end. So `class add AVR/Old` finds AVR under MCU, and asks which one if there are several.
    - **Missing parents:** when nothing matches, the path is read from the top level down. The parts that exist are used, and the missing ones are listed with `Create them? [y/N]`. No (the default) creates nothing.
    - **`--create-parents`:** creates them without asking, like `mkdir -p`. Without a terminal, missing parents are an error that names them and suggests `--create-parents`.
    - **`--parent P`:** the path is relative to P (`class add Clamps/Quick --parent Tools`).
    - **Not atomic:** every class or location is created with an API call of its own. If one fails (say a sibling of that name exists), the ones created before it remain, and the message says which were created.
    - **Completion:** Tab completes the parent part of the path (`Tools/H` → `Tools/Hand/`).

### Deleting a subtree

39. **`class delete` and `location delete` take `--recursive`** (added after review). It deletes the node and everything below it on the server, in one transaction: all or nothing.
    - **In use:** when any of the classes has items, or any of the locations has stock, nothing is deleted. The message lists where (`MCU/Intel/No (1 item)`) and suggests `--force`.
    - **`--force`:** deletes those items (with their values, stock rows and attachments) or stock rows too. It only works with `--recursive`.
    - **Confirmation, always:** `wtf` asks first: `Delete class MCU/Intel and the 3 classes below it, with 1 item? [y/N]`. A script must pass `--yes`, or it gets an error. `--verbose` lists everything that will be deleted before the question. The counts come from a preview on the server, `GET …/deletion`. It is a `GET` so that a server too old for recursive deletes answers 404, and the client stops ("update wtfd"), instead of mistaking the preview for a delete.
    - **A plain delete that fails** because of children or items now suggests `--recursive`.
    - **Single deletes** of items, stock rows, attributes and so on still don't ask (decision 14).

### Containers and edit forms

40. **Containers** (added after review). `--container` on `class add` and `location add`, and `--container yes|no` on `set`, mark a node that holds only other nodes. The server refuses items in a container class and stock at a container location, also for moves. A node can only become a container while it holds none.
    - **Display:** `tree` shows containers with a trailing `/` (`Hardware/`). Names can't contain `/`, so it's unambiguous, and it matches completion, which offers containers as a way through. `get` shows `Container: yes`.
    - **Completion:** when choosing a class for an item (`item add/set --class`, `item edit`) or a location for stock (`stock add/move/set`, `stock edit`), containers are offered only as part of a path (`Hardware/`), never as the choice itself. Lists and filters still offer every node.
    - **Created parents:** parents created by `add` with a path are not containers.
41. **Edit forms** (added after review; you chose a form in the terminal over a text file in an editor). `wtf <noun> edit <ref>` works for classes, locations, items, stock rows, attributes, accounts and attachments.
    - **Fields:** every field is asked in turn, with its current value filled in. Enter keeps it, Ctrl-U clears it, and Tab completes as in the other prompts. Values may carry units (`15mm`), and paths and names work as on the command line.
    - **Lists:**
      - **Class attributes:** an attribute name assigns or changes it (default, per unit, required), and `-NAME` removes an assignment of the class itself.
      - **Choice options:** `NAME` adds, `-NAME` removes, and `OLD=NEW` renames.
      - **Item and stock values:** one line per attribute of the class (per-unit ones for stock), and clearing a line removes the value, so the default applies again. Required values without a default can't be cleared.
    - **When changes are made:** only at the end, so Ctrl-C at any point changes nothing (exit code 130). They can take several requests. If one fails, the message says what was already saved (`Already saved: assigned Colour`). Then `Saved: …` or `No changes.`, and the object is shown.
    - **Fixed fields:** an item's or attribute's unit can only change to another unit of the same quantity, so it is only asked for when there is one, with Unit lock right after it. A stock row's item isn't in its form; use `stock set --item`.
    - **Accounts:** the form asks for the email, the role (viewer, user, admin) and the password (keep, set or remove).
    - **`--edit` on `add`:** creates the object (class, location, item, stock row, attribute, account or attachment), then opens its form. Without a terminal, `edit` and `--edit` fail before anything is created. Scripts use `set` and the other commands.

### Compartment boxes

42. **`location add "Box 3" --grid 8x5`** (agreed after review; a full grid model with merged compartments was rejected as too complex). It creates the box and one compartment per cell, named like spreadsheet cells:
    - **Size:** `8x5` is 8 columns (letters A–H) by 5 rows (numbers 1–5), so A1 … H5. B1 is right of A1, A2 below it, and after Z come AA, AB, ….
    - **Container:** the box becomes a container, so stock goes into the compartments.
    - **Nothing about the grid is stored:** the compartments are ordinary locations with their own label codes. A compartment covering two cells can be handled by deleting or renaming one of them, or by simply using either.
    - **On the server:** everything is created in one transaction (`grid` in `POST /locations`), so every future app has the same function. A failure leaves nothing behind.
    - **Big grids are confirmed** (changed after review; it was a limit of 1000 compartments). When the command would create more than 1000 locations (compartments, the box, and missing parents with `--create-parents`), `wtf` asks `This creates 1051 locations. Continue? [y/N]` before creating anything. Scripts must pass `--yes`. The server enforces the same rule: above 1000 the grid must carry `"confirm": true`, so every app has to ask.
    - **Natural sort order:** the class and location trees now sort numbers inside names by their value, so `A2` comes before `A10`, and `Shelf 2` before `Shelf 10`.

### Stock for new items

43. **`item add` offers stock** (added after review).
    - **The question** (changed after review: once, not after `--edit`): on a terminal, after the item is created, `wtf` asks once `Add stock for <item>? [y/N]`. Yes asks for the location (Tab completion skips containers), the quantity (Enter: uncounted) and the per-unit values, the same as `stock add`, and adds that one stock row. With `--edit`, the command ends with the form and doesn't ask.
    - **Errors:** if the stock row fails (say the location is a container), the command ends with `<item> was created, but its stock wasn't: …` (exit code 1). The item stays.
    - **Not asked:** without a terminal (scripts, pipes), or with `--json`, which prints only the item. Scripts add stock with `stock add`.
    - **Shared code:** `stock add` and these questions use the same code to create stock.

### The versioned API and cookie sessions

44. **Paths and sessions** (agreed before building; the details below I decided while you were away).
    - **API paths:** the CLI talks to `/api/v1/…`.
    - **The session:** it keeps the session token from the login cookie in its profile, and sends it back as the cookie `wtf_session`. Existing logins keep working, because the tokens are the same.
    - **`login --json`** no longer shows a token. The token is only ever in the cookie.
45. **Which side is out of date.**
    - **A server older than the versioned API** answers `/api/v1/…` with a 404 without `API-Revision`. The CLI then says "the server doesn't serve /api/v1; … update the server (wtfd)".
    - **"Unsupported API version"** from a server that only serves other versions gets "update this client" or "update the server", depending on whether those versions are newer or older.
    - **An older revision:** when the server's `API-Revision` is older than the one the CLI was built for, it warns on stderr after the command. Since revision 2, a server from before marking deleted gets that warning.
46. **Server details I decided:**
    - **The 401 challenge:** `WWW-Authenticate: Cookie realm="WtF", cookie-name="wtf_session"`. There is no registered scheme for cookie sessions, and HTTP requires the header on a 401.
    - **The cookie's lifetime:** every authenticated answer renews it, so it matches the session's "30 days from last use". A 401 for an ended session deletes it.
    - **`Secure`:** only over HTTPS, recognised directly or by `X-Forwarded-Proto: https`, so the web app also works over plain HTTP on a LAN.
    - **The `Origin` check:** it compares the host and port in `Origin` with the request's `Host`. `Origin: null` counts as another site.
    - **Web app caching:** every file is served `no-cache` (revalidated, 304 when unchanged) rather than cached for long, because Flutter's main files don't have fingerprinted names.
    - **`index.html` instead of a 404:** only for paths whose last part has no `.`, so missing scripts or images are a 404, not the app.
    - **The Content Security Policy** expects a Flutter build without Google's CDN (`--no-web-resources-cdn`). It may need adjusting once there is a real app.
    - **No `GET /api` overview:** as discussed, the "unsupported version" problem, the `Sunset` header and Flutter's `version.json` cover what it would have done.

### Deleted things

47. **Restoring** (2026-10-27) was dropped with "mark as deleted" on 1 November 2026 (decision 66): `wtf <noun> restore` and the `Deleted:` and `Merged into:` lines went.
    - **Errors** show the server's `hint` on a second line, e.g. how to delete a location that still has stock.

### Unit families, and no tenants

48. **Units instead of unit groups** (agreed before building). An attribute or item names one unit, such as mm, and that unit's family (Metric length) is what numbers are scaled between on output.
    - **Plain numbers** are in that unit. This replaces decision 23: there is no longer any guessing between a group's base unit and its only unit.
    - **`--unit-lock`** shows numbers always in the unit itself. It is off by default, and `set --unit-lock yes|no` changes it.
    - **`attribute add Length --unit mm`** needs no `--type`: with a unit, the type follows from the unit's quantity.
    - **A symbol that several families share** (`B` in decimal and binary bytes) means the same unit wherever it is typed, but `--unit B` must name the family, `--unit "B (Binary bytes)"`, because the family decides the display.
    - **`wtf unit-family`** replaces `wtf unit-group`. Units, families and quantities have integer ids.
    - **No tenants:** a profile is one server, and the `Transport` test hook is gone, since the tests no longer need a tenant's hostname.

### Attribute conditions

49. **`--where` on `find` and `item list`** (agreed before building). Repeatable; all conditions must match, together with the search words and `--class`.
    - **Numbers and dates:** `Resistance>=32k`, `=`, `>`, `<`, `<=`, and a range `Resistance=10k..47k`, both ends included. Units as anywhere else: any unit of the quantity, and a plain number in the attribute's unit.
    - **Choices:** `Package=0603,0805` is any of the options.
    - **Text:** `Notes~metal` contains, `Notes=metal film` is the whole text; both ignore case.
    - **Yes/no:** `Lead-free=yes`.
    - **What is compared** is what the item shows, class defaults included; a per-unit attribute matches when any stock row does (see [api/item.md](api/item.md)).
    - **The condition is split at its first operator,** so an attribute name can't contain `<`, `>`, `=` or `~`.

### Importing units

50. **`wtf unit import FILE [--dry-run]`** sent a unit file and told what was added (or would be), how much was there already, and every conflict. It is gone: `wtf model import` imports units now (decision 56).

### Attachments, redone
51. **Attachments follow the new model** ([api/attachment.md](api/attachment.md)): each object has attachments of its own, with a title, type and size, and a photo per object.
    - **An attachment is always named with its object:** `get`, `download`, `set` and `delete` take `TYPE REF ID`, like `list` and `add`.
    - **`add … [--title T] [--photo]`:** the title defaults to the file name.
    - **`photo TYPE REF ID|none`** sets or clears an object's photo, which must be one of its own image attachments. The photo is named after its object: "Item photo set.", and "item photo" in lists.
    - **`delete TYPE REF ID`** deletes it, for good.
    - **`download`** names the file as the server does: the title, with an extension for the type if it lacks one (`internal/mediatype`).
    - **No edit form, and no `add --edit`:** the title is all there is to change, with `set --title`.

### Tenants

Built with the server's tenants (TENANTS.md, removed with them on 2 November 2026), API revision 11.

52. **A profile is still one server address,** and the hostname in it picks the tenant: `wtf login https://smith.wtf.example`. Nothing else changes for logging in.
53. **Unit ids are strings** (UUIDs). `--unit` still takes a symbol, a name, `"B (Binary bytes)"`, or an id.
54. **`wtf quantity available <quantity> on|off|default`** and **`wtf unit-family available <family> on|off|default`** turn units on and off for the tenant (admins); `default` follows the global default again. `list` and `get` have an AVAILABLE column: yes or no, with "(chosen)" when it is the tenant's own choice rather than the default. Completion offers only available units; the server refuses the others, and refuses to turn off what attributes or items use, naming them.

### Model files

55. **`wtf model import FILE [--parent CLASS] [--dry-run]`** imports a model file ([seed/model-format.md](seed/model-format.md)): attributes and a tree of classes. It tells what was added (or would be), how much was there already, and every conflict, as `wtf unit import` did; with conflicts nothing is imported, and the exit code is 1. `--parent` puts the file's classes below a class instead of at the top. The cached class tree and attributes are dropped at once.
56. **Units come in model files** (API revision 12, [seed/model-format.md](seed/model-format.md), decisions 21–35), so `wtf unit import` is gone and `wtf model import` imports them: a file of only quantities is what a unit file was. The report lists added quantities, families and units too, and the cached units are dropped as well, so the new units can be used straight away.
57. **`wtf model export CLASS [-o FILE] [--force]`** writes the class with everything below it as a model file, indented, with its keys in the format's order: to stdout, or to FILE, which it won't overwrite without `--force`. It needs only read access.

### The refactor of November 2026

Built with the refactored API ([API.md](API.md), API revision 1 again; 2026-10-31-api-refactor.md).

58. **The database's names** in what `wtf` shows and takes: a stock row's **amount** (`--amount`, the prompts and the headings), `decimal` for the datatype, an assignment's scope. `class assign --per-unit` keeps its flag, and sends `scope: "stock"`.
59. **Units are looked up in the families `wtf` keeps** (`GET /unit-families`, revalidated by its version on every use, as the trees are): answers name units by id, and `wtf` fills them in.
60. **`wtf login --stay DURATION|forever`** says how long the session may sit unused: `forever` (until logging out), a Go duration (`12h`) or days (`30d`). The configuration keeps the last one given as the default for the next login; without one it is `forever`. The session's client name is `wtf on <host name>`.
61. **`wtf sessions list`** shows your sessions (* marks this one), and **`wtf sessions logout <id>`** or **`--others`** ends one, or all but this one. (`wtf sessions` alone shows the group's help, as for every group.)
62. **A new password asks about the other sessions:** `wtf password` asks "Log out your other devices too?", or takes `--log-out-others` or `--keep-others`; an admin's `wtf account set --password` or `--no-password` asks about the account's sessions, or takes `--log-out` or `--keep-sessions`, and the edit form asks too.
63. **`wtf … history`** paged by `--before`, until history went (decision 66).
64. **Creating always sends every field** the API requires, with null or the old default where none is given; `wtf account add` without `--role` still makes a viewer.
65. **A restore into something deleted** was recognised by its problem type, until restoring went (decision 66).

### Without "mark as deleted" and history (1 November 2026)

[2026-11-01-dropping-deleted-and-history.md](2026-11-01-dropping-deleted-and-history.md).

66. **No `restore` and no `history`:** a delete is final, and a backup is the way back (README.md, "Backups").
67. **Deleting asks first on a terminal:** `Delete stock 1A7K? This can't be undone. [y/N]`, unless `--yes`. Without a terminal it doesn't ask, so scripts delete as before; a single delete is refused while anything is in or uses what it deletes. A recursive delete still needs `--yes` in a script.
68. **`wtf stock merge <stock> <into> [amount]`** adds a stock row, or part of it, to another row of the same item with the same values; all of it deletes the row. `wtf stock move` never merges.
69. **`wtf code`** of a deleted thing's label says that it has been deleted (410), where a code never handed out isn't found.

### Attributes in JSON, and no tenants (2 November 2026)

[2026-11-02-attributes-in-json.md](2026-11-02-attributes-in-json.md), decisions 43–48:

70. **An attribute is a flag of its own** in `item add`, `item set`, `stock add` and `stock set`: `--colour Blue` sets it, `--no-colour` removes it, and `--default colour` (as often as needed) puts it back to the class's default. Letter case is ignored and a hyphen stands for a space; a flag that matches two attributes is refused, saying which. Flags the command doesn't define are taken as attributes before the command's own are parsed, so an attribute named like one of them (`--json`, `--yes`, `--edit`, …) is set with `--value NAME=VALUE`. The database refuses attribute names of the fixed fields (`name`, `class`, `unit`, `photo`, `amount`, `reference`, `serial`, …), so those never clash.
71. **`wtf class attribute add|set|rename|remove` and `wtf class choice add|rename|remove`** change a class's attributes, on the class that defines them. Each takes `--dry-run`, and says what it wrote ("Rewrote 1,204 items."); `remove` asks first on a terminal. A noun can be two words: `class attribute` is a noun of its own beside `class`. The groups `attribute`, `option`, `attachment`, `quantity`, `units` and `unit-family` are gone, with `class assign` and `unassign`, `item value-set` and `value-delete`.
72. **Units are labels:** `--unit mm` on an attribute or item says what its numbers are in, and a number may carry it (`--length "12 mm"`); nothing converts, so another unit is refused.
73. **`wtf file put|get <item or stock row> <attribute|photo> FILE`** uploads and downloads files. A label code says which of the two it is, `ITEM@LOCATION` is a stock row, and anything else an item. Without a file name, `get` names the download as the server does (`Manual.pdf`); `-` writes it to stdout. A photo or a file is removed with `set --no-photo` or `--no-<attribute>`.
74. **Lists show one page** and say when more follow; `--all` follows the pages to the end (the API pages by key, with no total). `--offset` is gone.
75. **`wtf stock merge`** asks, on a terminal, which row's value to keep for each difference (reference, serial, photo, a value), and takes `--keep FIELD=from|into` in scripts; without a terminal, a difference that `--keep` doesn't settle is an error that lists them all.
76. **Profiles have the server's address only** (decision 41 of the plan): there are no tenants to pick by hostname.
