# WtF apps – design

**Status: the first version is built for web and Windows, not yet reviewed.** The decisions taken in review, and the ones I took while building, are listed at the end.

The apps are one Flutter program for every platform: web, Windows, macOS, Linux, Android (phones, tablets and Chromebooks) and iOS/iPadOS. Flutter is Google's toolkit for building apps from one codebase. Its programs are written in Dart, a typed language that resembles Go, Java and JavaScript.

## The first version

It was planned to cover what you do every day. While building it, it grew to cover almost all of the CLI (decision 5). The CLI covers the rest.

| In the first version | Later |
|----------------------|-------|
| Log in and out, change your password, your sessions | |
| Search, and browse the location and class trees | Label scanning |
| Look at an item: values, files, stock and where it is, its photo | |
| Add items (with their values), stock and locations (also with a compartment grid) | |
| Move and merge stock, and edit and delete items and stock rows | |
| Manage classes with their attributes, locations, and accounts | |
| Photos of items and stock rows, and the files of attachment attributes: upload, open, save, remove | |

Since the plan of 2 November 2026 ([2026-11-02-attributes-in-json.md](2026-11-02-attributes-in-json.md)), attributes are part of their class, units are labels, and there is no history, restore or attachment of its own any more; decisions 72–82 describe the app since then.

**Platforms, in this order:**
1. **Web and Windows:** on your PC, where everything is installed.
2. **Android:** after installing Android Studio.
3. **iOS, iPadOS and macOS:** on the Mac Mini.
4. **Linux.**

## Where it lives

The app is a folder in the same repository, `app/`, so one version tag covers server, CLI and apps:

```
app/
  .fvmrc                 pins the Flutter version (3.47.8), for FVM
  pubspec.yaml           the app's name, version and packages (like go.mod)
  lib/                   the app's own code
    main.dart            start-up
    api/                 the API client: requests, sessions, errors, data types
    screens/             one file per screen
    widgets/             building blocks used by several screens
  test/                  tests
  android/ ios/ macos/ windows/ linux/ web/
                         per-platform shells that Flutter creates and builds; rarely touched
```

- **App ID:** `io.bbj.wtf` on every platform; it can't change after the first store release.
- **Names:** "Where to Find" in the stores. Under the icon on a home screen, the shorter "WtF" fits better.

## Talking to the API

A small hand-written Dart client, the counterpart of the CLI's Go client (`internal/client`):

- **One method per API call:** for example `item(id)` or `moveStock(id, location, amount:)`, returning Dart classes such as `ItemDetail` and `Stock` (`app/lib/api/client.dart`, `models.dart`).
- **Server address:**
  - The **web app** uses its own address, because `wtfd` serves it, so there's nothing to enter.
  - The **native apps** ask for the server address at login and remember it, like `wtf login --server`.
- **The session:**
  - **On the web,** the browser handles the cookie by itself. The app never sees the token.
  - **In the native apps,** the client reads the token from the login answer's cookie and keeps it in the system's protected storage (Keychain on Apple, Keystore on Android, Credential Manager on Windows, Secret Service on Linux). It sends it back as the cookie.
- **Versions:** the same checks as the CLI.
  - **The revision:** the app compares `API-Revision` with the revision it was built for.
  - **Wrong version or no versions:** "unsupported API version" and "no `/api/v1` at all" become clear messages: "update the app" or "update the server".
  - **Web updates:** the web app also compares Flutter's `version.json` with its own version, and reloads itself after an update, at a safe moment, never in the middle of a form.
- **Errors:** the API's problem details become readable messages on screen.
- **A test keeps it honest:** it reads `openapi/openapi.json` and checks that every path the client uses exists there, like the server's route test.

## Screens and URLs

Every screen has a URL. In the web app it shows in the address bar, and it works as a link, a bookmark and after a reload (`wtfd` answers app URLs with `index.html`). Items, stock rows and locations use their label codes, which are short and printed on labels anyway. Classes have no codes, so they use their ids.

| URL | Screen |
|-----|--------|
| `/login` | Log in. The native apps also ask for the server address. |
| `/` | Items: the search form (words, a class, and its attributes), like `wtf find`. The start screen. |
| `/found?search=&class=&where=` | The items found, and where they are. Opened by the form, on top of it. |
| `/locations` | The location tree. Containers are marked, and grids show their compartments. |
| `/locations/1A7K` | A location: its path, what's below it, and the stock at it and further in. Edit, add a location inside, delete (with everything below it). |
| `/locations/new?parent=…` | Add a location, optionally with a compartment grid (`8 × 5`). |
| `/locations/1A7K/edit` | Edit a location: name, parent, container. |
| `/classes` | The class tree. |
| `/classes/<id>` | A class: its attributes (add, change, rename, remove, and a choice's choices, each previewed by a dry run), the classes below it and its items. Edit, add a class below, export, delete. |
| `/classes/new?parent=…`, `/classes/<id>/edit` | Add or edit a class: name, parent, container. |
| `/items/1B2C` | An item: its details and values, its photo, its files, stock rows with their locations. A stock row's code shows its item too, as in the CLI. |
| `/items/new?class=…` | Add an item: class, name, the unit of its stock, then its attributes in the class's order. Afterwards it offers to add stock, like the CLI. |
| `/items/1B2C/edit` | Edit an item: name, class, the unit of its stock, values. |
| `/stock/1C3D` | A stock row: amount, location, reference, serial, its values and files; move it (all or part), merge it into another row, edit or delete it. |
| `/stock/new?item=…&location=…` | Add stock: item, location, amount, reference, serial, the values of the stock attributes. |
| `/stock/1C3D/edit` | Edit a stock row: location, amount, reference, serial, values. |
| `/me` | Your account: email, role, appearance (light, dark or as the system), your sessions, change password, log out. |
| `/admin` | For admins: links to classes and accounts; importing and exporting model files (decision 69). |
| `/accounts`, `/accounts/<id>` | The accounts: email, role, password (keep, set or remove). |

**Choosing things:** wherever a location or class must be chosen, a picker with search and the tree replaces the CLI's typing with Tab. A number is typed as it is, or with the label of its unit (`12` or `12 mm`), and checked as you type, with the same rules as the CLI (decision 74).

## Layout: one design for every screen size

Flutter has standard size classes, measured in logical pixels, which are independent of the screen's resolution:

| Width | Typical device | Navigation | Content |
|-------|----------------|------------|---------|
| under 600 | phone | bar at the bottom: Items, Locations, Admin (admins only), Account | one screen at a time |
| 600–840 | small tablet, phone sideways | rail on the left | list and details side by side where it fits |
| over 840 | tablet, desktop, browser | rail on the left | list and details side by side, the tree always visible |

- **Look:** Material 3, Google's current design system, which Flutter has built in. Light and dark follow the system setting, unless you choose one on the Account screen (decisions 6 and 86).
- **Desktop and web:** keyboard shortcuts, such as `/` to search and `Ctrl+N` for a new item. Mouse hover and right-click menus come where they help.

## Packages

A "package" is a ready-made Dart library, like a Go module. We'd use only a few well-established ones:

| Package | What it's for | Who maintains it |
|---------|---------------|------------------|
| `go_router` | Screens and their URLs, including the browser's back button and links into the app | the Flutter team |
| `http` | Sending requests to the API | the Dart team |
| `provider` | Sharing data between screens, such as who is logged in or the current item, and redrawing a screen when it changes. It's the simple approach Flutter's own documentation recommends. | the Flutter community; recommended in the Flutter docs |
| `flutter_secure_storage` | The native apps' protected storage for the session token | widely used community package |
| `shared_preferences` | Small settings, such as the native apps' server address | the Flutter team |

Testing uses `flutter_test`, which is built into Flutter.

## Developing

- **`fvm flutter run -d windows`** starts the Windows app with *hot reload*: after saving a change, the running app updates within a second, keeping its state. The Windows app talks to `wtfd` directly, like the CLI, so no browser rules apply.
- **`fvm flutter run -d chrome`** does the same for the web app. But it serves it from its own port, so the browser treats `wtfd` as another site and blocks the requests, unless `wtfd` allows that one development address (see question 2).
- **`fvm flutter build web --no-web-resources-cdn`** builds the web app for `wtfd --web-root`. The option makes Flutter bundle its engine and fonts instead of loading them from Google, as `wtfd`'s security policy requires.
- **CI:** once the app exists, the workflow gets a job that checks the code (`flutter analyze`), runs its tests and builds the web app. As always, it calls a script in `scripts/` that anyone can run.

## Decisions

1. *Gone with the units (decision 74).* **Numbers with units are converted by each client, for now.** The API keeps taking numbers in the base unit of the quantity, as before. Each client turns `12mm` into `0.012` itself and checks it while you type, so mistakes are caught at once. The CLI does this today (`internal/cli/units.go`), and the apps get the same rules in Dart. Doing it on the server was tried, and set aside because prompts and forms could then only report mistakes when saving.
2. **No `--dev-origin` for now.** Development uses the Windows app, which needs nothing on the server, and the web app is tested through `--web-root`. The switch can come later if web development without hot reload becomes a nuisance.
3. **The start screen is search.**
4. **The name under the icon is "WtF",** and in full "Where to Find". It was "Where the Fxxx" until it was renamed before the first App Store review, so the stores have nothing to object to.

## Decisions made while building

These are decisions I made without you, recorded for review. You asked me to copy as much of the CLI as possible, and to use my own judgement.

### What it covers

5. **Almost all of the CLI.** Everything except:
   - **What needs new packages:** uploading and downloading attachments. (Both came later, with `file_picker` and `image_picker`: decisions 35 and 38.)
   - **What only makes sense in a terminal:** `--json`, the pager, shell completion, profiles. The native apps remember one server, and the web app uses its own.
   - **Creating by path** (`class add MCU/AVR/Old`, with missing parents): the app has a parent picker instead, and names can't contain `/` anyway.
   - **Moving a stock row to another item** (`stock set --item`): rare, and easy to get wrong with a tap.
6. **Attributes, units and accounts live under Manage** (your choice, replacing my first version, which had them under Me). Manage is a fifth destination, between Classes and Me, and shows Accounts only to accounts that may read them. Me keeps what is about you, plus the **appearance**: Follow system (the default), Light or Dark. That is kept on the device, not with the account, so your PC and your phone can differ. In a browser it is kept by that browser. When more destinations come, narrow screens will get a "More" entry listing the rest (your plan).

### Finding and choosing

7. **Search works like `wtf find`.**
   - **What it shows:** each found item with its class and where each of its stock rows is. As in the CLI, that takes one request per item, so results come 20 at a time, and more load as you scroll.
   - **Typing:** the search starts with the Search button or Enter (decision 29).
   - **Label codes:** a single word that could be a label code is also looked up as one (`wtf code`). If it exists, its item, stock row or location is shown above the results.
   - **Class filter:** a field next to the search narrows it to a class (`--class`).
8. **Pickers replace Tab completion.**
   - **How they work:** a list with a search field. Every word you type must occur in the path, ignoring case, and Enter takes the first match.
   - **Containers:** where a location for stock or a class for an item is chosen, they show greyed out. So the tree stays recognisable, but they can't be picked, as with the CLI's completion.
   - **What can't be chosen:** a node's own subtree isn't offered as its new parent, and a stock row's current location isn't offered as where to move it.
9. **URLs.**
   - **Items, stock rows and locations:** by label code. The screen looks the code up (`/codes/…`), as the CLI does with references.
   - **Classes, attributes and accounts:** by id.
   - **The address bar:** in the web app it follows every screen, including ones opened on top of another, so each one can be bookmarked.

### Changing things

10. **Deleting always asks first.** That differs from the CLI's decision 14, where single deletes don't ask. A tap goes astray more easily than a typed command.
    - **Locations and classes:** deleting one shows the server's preview of everything below it, like `delete --recursive`. If stock or items are in them, Delete only becomes possible once "Delete that stock too" (`--force`) is ticked. Everything happens in one transaction on the server.
11. **Forms save at the end, as the CLI's edit forms do.** *Since decision 73, in one request.*
    - **What is sent:** only what changed, in several requests if needed (the item, then each value).
    - **When a request fails:** the message lists what was already saved ("Already saved: name").
    - **Values:** clearing one removes it, so the class default applies again. A required value without a default can't be cleared.
    - **Existing values:** they appear as shown elsewhere (`18 V`, `32 KiB`), which reads back to the same number. So saving without changes sends nothing.
12. **New items.**
    - **Stock afterwards:** as in the CLI (decision 43), the app asks once "Add stock for …?". Yes opens the stock form, and the item's screen follows.
    - **Units:** a new item can have any unit, or none: it is counted. An existing item can only change to another unit of the same quantity, and only if it has one (CLI decision 41).
13. **Moving stock.**
    - **How much:** an empty quantity moves all of it. Uncounted rows can only move whole, so they get no quantity field.
    - **What you see afterwards:** the server answers with the row at the destination, which may be the same row, a new one split off, or one it was merged into. The app shows that row.
14. **Grids.**
    - **The form:** two fields, columns and rows, with a preview ("40 compartments, A1 … H5").
    - **Big grids:** over 1000 locations, the app asks first and then sends `confirm`, as the server requires.
    - **Parents:** missing parents aren't created (decision 5).
15. **Privileges.** Buttons for changes the account may not make are hidden: data write for items, stock and locations, model write for classes and attributes, account write for accounts. The server checks anyway. (Locations were first wrongly tied to model write; fixed with decision 24. Since decision 69, roles.)
16. **An ended session sends you to the login.** A 401 means the session has ended. The native apps also notice the deleted cookie, while the web app notices the 401.

17. **What this app adds or changes shows at once** (your rule, not a decision of mine). The client keeps the class and location trees for the session, and revalidates them on every use. After a change to a tree (adding, renaming, moving or deleting a class or location, grids included), it fetches that tree again before the change counts as done. It then tells every screen still showing that tree, including the screens underneath, which load again. Unit families and units are kept for the session as well, but they can't be changed through the API.

### Numbers

18. **Exact, as in the CLI.**
    - **Arithmetic:** the conversion uses exact fractions, with the CLI's tests ported to Dart.
    - **Sending:** numbers go into the JSON exactly as decimals, even ones a Dart `double` can't hold, such as `0.333…` to 30 places.
    - **Reading unit factors:** they are taken as the exact text the server wrote. Dart's JSON decoder would round them to a `double`, and some factors in the dev database have more digits than that holds: °F's factor is `0.55555555555555555556`, and its offset is `255.37222222222222222`. A test checks that 100 °F becomes exactly the CLI's `310.927777777777777776`.

### Not done yet

19. **Not built:**
    - **Wide screens:** the plan has lists and details side by side, and the tree always visible. For now wide screens get the narrow layout, centred, with the rail.
    - **Keyboard shortcuts:** `/` to search and `Ctrl+N` for a new item.
    - **CI:** the job that runs `flutter analyze`, the tests and the web build. GitHub's runners need Flutter installed, either by a ready-made action such as `subosito/flutter-action` or by a script of ours. That is your choice.

### Tests

20. **Automated:** 38 tests in total.
    - **Unit tests:** units, dates, codes and grids, with the CLI's cases.
    - **The API client:** cookies, error messages, version checks, exact numbers in request bodies, and a changed tree being fetched again at once.
    - **Against `openapi.yaml`:** every method and path the client uses must be in the spec.
    - **Widget tests:** they run the whole app against a pretend `wtfd` (`test/fake_server.dart`). They cover logging in and out, search, label codes, moving part of a stock row, adding an item with a value in other units (`18000mV` is sent as `18`), adding its stock, editing and clearing values, the location tree, a compartment grid (and the tree underneath showing it at once), deleting a location with stock, a read-only account, the Manage destination, the appearance being kept, a deleted location restored with what it is in, the history screen, and the history of the top level. Unit tests turn history entries into sentences against the pretend server.
21. **Against the dev server:** every reading call of the client ran against `wtf` (as Development Tenant, reads only). The test that did this isn't kept, because it depends on your data. Nothing was changed in the database.
22. **Not tested by hand:** I can't click through the app myself. The Windows and web builds succeed, but nobody has looked at the screens yet.

### History and deleted things

Added after review, with the deletion design ([api/deleting.md](api/deleting.md)). *Gone with the plan of 1 November 2026: there is no history, nothing is marked deleted, and nothing is restored (decision 80).*

23. **History in words** (agreed with you before building).
    - **One card per action:** the entries of one transaction, with the time and who did it, under a heading per day ("Today", "Yesterday", "Mon 26 Oct 2026").
    - **Sentences with names, not ids:** "Added 2 at Garage/Shelf 1 (1C00)", "Voltage: 12 V → 18 V", "Renamed from “Drill” to “Cordless drill”". Classes and locations come from the trees, deleted ones are fetched by id, and the rest from the entries themselves, the attributes and their units. Numbers are shown as the server's `display` does: in the unit of the family that fits best, or in the unit itself with Unit lock.
    - **Whose history it is** decides the wording: in a location's history a stock row is named by its item ("Cordless drill (1C00) moved here from Garage"), in an item's history by its location.
    - **Actions that change several rows are one line:** a split or merge is "Moved 1 from A to B, into a new row 1C05", a grid is "Added Box with 40 compartments (A1 … H5)", and a box deleted with what was in it is "Deleted Box, with 40 locations inside and 2 stock rows". More than 8 lines per action are cut off with "… and N more changes".
    - **Lines lead to what they name,** deleted things included. That is how deleted things are found again (deletion decision 1).
    - **The raw entries stay available:** tapping a card shows them as the server sent them.
24. **Deleted things.**
    - **Their screens** show a red "deleted" banner, with when and by whom (from history, with the history privilege) and **Restore**. Editing, adding and deleting are hidden, since the server refuses them.
    - **Restoring into something deleted** asks: "Restore the location too", or "Somewhere else…", which opens the picker. The CLI asks the same.
    - **A stock row a move merged into another** says so and leads to that row; a label code of one goes there straight from search.
    - **Label codes** of deleted things are shown as "…, deleted" in search.
    - **Privileges:** while building this I noticed that the app tied locations to model write, but the server ties them to data write (ACCOUNTS.md). The location buttons now follow data write.
    - **Not built:** restoring options in the app. The CLI can (`wtf option restore`); deleted options have no screen of their own in the app yet. (Attachments aren't restorable at all; see decision 34.)

### Unit families, and no tenants

Built for API revision 3, with the server's change to units (CLI.md decision 48). *Decisions 25–27 are gone with the units (decision 74).*

25. **A unit menu next to every number field** (your design). The field takes a number, and the menu next to it offers the units of the attribute's or item's family, starting at its own unit: for a length in mm, nm … km.
    - **A plain number** is in the unit picked in the menu.
    - **A number typed with a unit** (`1in`, `18000mV`) ignores the menu, and any unit of the quantity is accepted, also from another family, as in the CLI.
    - **Saving converts** to the base unit, exactly, as before. The menu only says what a plain number means; it isn't stored.
    - **Quantities of stock** get the same menu, from the item's unit.
26. **Choosing a unit** (attributes and items) lists every unit, filtered by symbol, name, family or quantity: "mm, millimetre · Metric length · Length". For a new attribute, choosing a unit sets the type to its quantity's (float, or integer for pieces), as `wtf attribute add --unit` does.
27. **Unit lock** is a switch under the unit, off by default. Its line says what it does with that unit: "Always shown in mm", or "Shown in the unit of Metric length that fits best". Units are shown as "mm (Metric length)", with ", locked" when it is set.
28. **No tenants:** Me shows the server instead of the tenant.

### The Items tab

Built for API revision 4, with `where` on `GET /items` and `--where` in the CLI (CLI.md decision 49). Your design.

29. **Items replaces Search.** The first tab is called Items. It is a search form, and nothing is searched until you press Search (or Enter).
    - **Layout:** on wide screens the search field, the class and the Search button share a row; on narrow ones the class and the button share a row under the search field.
    - **An empty search** lists every item.
30. **With a class, its attributes are searched too:** its own and inherited ones, as `wtf class get` lists them.
    - **Numbers and dates** take `32k` (exactly), `> 32kohm`, `>= 32 kohm`, `<= today` or a range `10k..47k`, both ends included. A number field has the unit menu, as in the item form; a typed unit wins, and any unit of the quantity is accepted.
    - **Choices** are chips; any of the chosen options matches.
    - **Yes/no** is Any, Yes or No.
    - **Text** is "contains", ignoring case.
    - **Per-unit attributes** are marked "(per unit)", and match when any stock row does.
    - **A condition that doesn't parse** is shown at its field, and the search doesn't start.
31. **Results replace the form.** They open on top of it at `/found`, so Back returns to the form with everything still filled in. The URL holds the search, so it can be reloaded or bookmarked; the form itself isn't restored from it.
32. **Results in two shapes.**
    - **Narrow (under 720 points):** compact rows, as before: name, code, class, stock, and where each stock row is.
    - **Wide:** a table with the item, its class, stock and locations, and a column for every attribute the found items have values for. Only the items' own values: per-unit ones belong to stock rows, and are shown on the item and the stock row (your choice, after a long per-unit value stretched rows). Each cell ends after three lines, the rest in a tooltip. Columns appear in the order they are first seen, so they don't move as more rows load. Class defaults are shown in grey italics. The table scrolls sideways when it doesn't fit, and then says so: the horizontal scrollbar always shows, with its track, and the right edge fades while columns are out of sight (Flutter's desktop scrollbars otherwise appear only while scrolling or under the pointer). The vertical scrollbar stays on the screen's right edge, not the table's.

### Importing units

*Gone with the units (decision 74).* Built for API revision 5, with unit files and `POST /units/import`. Unit files are part of model files now, and the Units screen imports those (decision 61).

33. **Import on the Units screen,** for accounts with the model write privilege, like `wtf unit import`.
    - **Choosing the file** uses the `file_picker` package, a new dependency. It works on the web, Windows, Android and iOS, and the Windows and web builds succeed with it. If you'd rather not depend on it, pasting the JSON into a text box would do instead.
    - **A preview comes first** (a dry run): what the file adds, by quantity, family and unit, and how much of it is there already. Import then imports it, and the screen shows the new units at once.
    - **Conflicts** are listed with where they are and why, and then there's only Close: nothing is imported until the file is fixed.
    - **The file is sent as it was chosen,** so factors keep every digit.
    - **A file that isn't a unit file** is refused with the server's reason, such as a missing key or a newer version.

### Attachments, redone

Built for API revision 7, with the new attachment model ([api/attachment.md](api/attachment.md)). *Decisions 34–38 are replaced by photos and attachment attributes (decision 75).*
34. **Titles and photos.** An attachment shows its title, and files their type and size. Each attachment's menu has:
    - **Title…** to rename it;
    - **Make it the item photo** or **No longer the item photo** for images (class photo, location photo, stock row photo for the others), which sets the object's photo (its list entry says "Item photo", …);
    - **Delete…**, which asks first and warns that it can't be restored.
    - **History** names attachments by their latest title: "Added image Front", "Renamed attachment …", "Item photo: Front view", "Deleted image …". "Photo" only ever means an object's photo; an image file is an "image".

### Uploading, photos and deleted attachments

Built for API revision 8: attachments are marked deleted again, and restored ([api/attachment.md](api/attachment.md)).

35. **Add files** on every item, stock row, location and class that the account may change, next to Attachments. It chooses one or more files (`file_picker`).
    - **One file:** a dialog asks for the title (the file name by default) and, for an image, offers "Make it the item photo" (or class photo, …).
    - **Several:** each is attached under its file name. If one fails, the message says which were attached already.
    - **The type** is sent from the file name's extension when it is a common one (images, PDF, text, Office, CAD); otherwise the server detects it.
36. **Take a photo,** with a new dependency, `image_picker`, which uses the camera. It shows in the Android app (decision 50) and on the web on phone-sized screens, where the browser opens the camera. It will work in the iOS app once that is added (iOS then needs a camera usage description). Desktops don't show it.
37. **Deleted attachments are found through history,** as you chose: the lines about an attachment ("Added …", "Deleted …", "Restored …", "Renamed …") lead to an attachment screen. It shows the title, type and size, and an image itself. A deleted one has a banner with **Restore**, which brings it back as an ordinary attachment. A file in an object's list opens the same screen.
38. **Downloading** an attachment: **Download…** in its menu, and a **Download** button on the attachment screen (a floating button, like Add stock). The app fetches the file with the session and saves it: the browser downloads it on the web, and the native apps ask where to save it (`file_picker`). The file name is the one the server gives, as in the CLI: the title, with an extension for the type when it lacks one. The native apps can't hand the browser a link, because the browser doesn't have their session.

### How photos and attachments look

39. **Small photos in both result views.** The narrow list and the wide table show an item's photo small (48 pixels) beside its name. The table keeps a column for it, so names line up when only some items have photos. A class's list of items shows them too.
40. **The object's photo on its screen:** to the right of the details on a screen at least 600 pixels wide (at most 240 by 320), and under the details, as wide as the screen, on a narrower one, which puts it just above the next section (Stock on an item). Tapping it opens it full size. Items, stock rows, locations and classes all do this.
41. **One list of attachments.** Images show their small version where other files show their type's icon (decision 55), so titles line up; tapping either opens the attachment screen, and tapping the small image opens it full size. The photo's line says "Item photo" (class photo, …) before its type and size, instead of a star. 42. **A thin border around photos,** small and large, in the theme's outline colour, so a photo whose background is just off the app's doesn't look misplaced.
43. **An item's values are details,** right under Code, Class and Stock in, without a "Values" heading. Stock rows keep the heading, since their own details (item, location, quantity) are of another kind.
44. **Buttons in a section heading take at most half its width** and wrap onto a second line, so Take a photo and Add files fit on a phone.

### Photos in the trees, and framed icons

*Classes and locations have no photos since decision 75; the framed icons stay.* Built for API revision 9: the class and location tree nodes include their `photo` ([api/attachment.md](api/attachment.md)). Revision 10 adds the stock row's `photo` to stock lists and the item's `photo` to item summaries, such as the item of a stock row.

45. **A photo or a framed icon** at the start of every list entry for an object: the object's small photo, or, when it has none, its icon in a frame the same size. That covers attachments (the paperclip), items (narrow list, wide table, a class's items), an item's stock rows (the row's own photo, else its location's), a location's stock (the row's own photo, else its item's), what's inside a location, the classes below a class, and both trees. The frame is the same thin border as the photos', so entries with and without a photo look alike and their names line up.
46. **The trees use a smaller size,** 36 pixels instead of 48, so they stay compact. Their rows are 48 pixels high instead of 44.

### App icons

47. **The icons come from [logo/](logo/):** the square icon (`icon.svg`) for the app, not the horizontal or stacked logos.
    - **Web:** `favicon.ico` (16, 32 and 48), with `favicon.svg` for browsers that take SVG; `icon-192.png` and `icon-512.png` in the manifest; `apple-touch-icon.png` for iOS home screens. The manifest's and the page's theme colour is the logo's orange, `#ff7828`.
    - **Maskable icons** (Android crops them to its own shape) come from `logo/icon-maskable.svg`: the same stack, smaller, on a full orange square, so nothing is cut off.
    - **Windows:** `app_icon.ico` holds the favicon PNGs at 16, 32 and 48 pixels, and `icon.svg` rendered at 64, 128 and 256 (with headless Chrome).
    - **iOS:** `icon.svg` without its rounded corners, a full orange square, since iOS rounds icons itself; without an alpha channel, which the App Store refuses. **macOS:** `icon.svg` as it is, 824 of 1024 pixels with a transparent margin, the size of the Mac's other app icons. Both rendered with headless Chrome (decision 70).

### Image memory

48. **Images are decoded at the size they're shown,** not at full size. A 12-megapixel phone photo decoded in full takes about 48 MB, so Flutter's 100 MB image cache held only two. Small photos are decoded at twice their size (so the square crop stays sharp for images up to twice as long as wide), the object's photo at most as large as its box, both in device pixels. Only the full-screen view decodes the original, for zooming. The whole file is still downloaded; smaller files from the server would be the next step.

### Colours

49. **Teal or the logo's orange,** chosen on the Me screen next to Light and Dark, and kept on the device like them. Teal stays the default. Both are Material colour schemes built from one colour, light and dark (`lib/theme.dart`).
    - **Orange** uses Material's "fidelity" scheme, which keeps the logo's `#ff7828` itself as the container colour (floating buttons, selected items). The usual scheme would turn it brownish. Text and outlines get darker orange in light mode (`#a04100`) and lighter in dark mode (`#ffb692`), so they stay readable.
    - The web app's browser colour (decision 47) stays orange whichever is chosen: it is fixed in the page, before the app has started.

### Android

50. **The Android project** (`app/android/`), made with `flutter create`. Building it waits for Android Studio, which brings the SDK and a Java JDK.
    - **Package name `io.bbj.wtf`,** as you chose. It can't change once the app is installed or published.
    - **The app is called WtF.** It may use the internet. **Plain HTTP is allowed,** because `wtfd` leaves HTTPS to an optional proxy, so a phone can reach a server on the home network without one. The session token then travels unencrypted, as it does to the Windows app.
    - **The launcher icon** comes from the logo. Older Androids get `icon.svg`, rendered at the five densities. Android 8 and later get an adaptive icon: the stack (`logo/icon-android-foreground.svg`, scaled into the safe zone) on the logo's orange, which every launcher shape shows whole. The same layer is the monochrome icon for Android 13's themed icons.
    - **No camera permission** is needed: `image_picker` hands the photo to the phone's camera app. Choosing and saving files go through Android's own file dialogs (`file_picker`), so no storage permission is needed either.
    - **Building** (`flutter build apk`) needs the NDK version Flutter asks for. The new Android command-line tools no longer let Gradle install it on its own, so it is installed with `android sdk install ndk/<version>`. Kotlin's incremental compilation is off (`kotlin.incremental=false` in `gradle.properties`): its caches fail when the project (H:) and Flutter's package cache (C:) are on different drives. The APK runs on Android 7.0 (API 24) and later.
    - **Release builds are signed with the debug key** for now (Flutter's default), which is enough for installing on your own phones. A store release needs a key of its own, kept out of git (`key.properties` and keystores are ignored).

### Values

51. **URL values are links** (your idea), on item and stock row screens and in the results table. A tap opens them in the browser (a new dependency, `url_launcher`, from the Flutter team). A right click or a long press opens a menu with **Open link** and **Copy link**. In the web app the browser's own menu is held back while the pointer is on a link, so ours shows instead. In the table a tap on the link opens the link, not the item. Android lists `http` and `https` among the intents it queries, which Android 11 and later need before opening a link in another app.
52. **Assigning an attribute asks for the default value,** labelled "Default value" with "Empty: no default" under it. The field was labelled with the attribute's name, which made it look as if the dialog renamed the attribute (your find). The attribute's name is in the dialog's title.
53. **A class lists Item attributes and Stock attributes** (per unit) under their own headings, and leaves out a heading with nothing under it (your design). Assign sits on the first heading shown. A class without attributes shows only an "Attributes" heading holding Assign, and only to accounts that may assign. "per unit" left the attributes' descriptions, since the heading says it.

### Opening attachments

54. **Open, beside Download,** in an attachment's menu and on its screen, where it is the main button and Download moves next to the title. It's offered only for types that show their content and run nothing; the rest are Download only, as before.
    - **The web app** opens the file's address in a new tab, and the browser shows it. That covers what the server sends inline: images (not SVG), PDF and plain text. The session cookie goes along, since the app itself opens the tab.
    - **The native apps** download the file to the app's temporary files and hand it to the device's app for its type. Besides those types they open Markdown, CSV, JSON, ZIP, Word, Excel and PowerPoint (the current formats, without macros), OpenDocument, MP3, M4A, MP4, MOV, STL and STEP. Not programs, scripts, web pages, SVG, Office files with macros or the old Office formats (`.doc`, `.xls`), which can carry macros.
    - **The file's name** is the title with characters that file systems or shells treat specially replaced, and it always ends in the type's extension ("setup.exe" as a PNG opens as `setup.exe.png`). The device picks the app by that extension, so it can't be made to run something. Each file's copy sits in a folder named by its hash, so opening it again reuses the copy.
    - **Android and iOS** go through `open_filex` (a new dependency), which shares the file through the system. Its storage and media permissions are removed from the manifest: the app only opens its own copies. **Windows, macOS and Linux** open a `file:` address with `url_launcher`. `open_filex` would run `cmd /c start` on Windows, where a title with `&` in it would act as a command. `path_provider` (also new, from the Flutter team) finds the temporary files.
    - When no app on the device takes the type, a message says so and suggests Download.
55. **Icons by file type** (your idea), from Material's own icons, so nothing is added to the app. They show in the attachment list and, large, on a file's attachment screen. Common sub-types have their own: PDF; word processing (Word, OpenDocument, RTF); spreadsheets (Excel, OpenDocument, CSV); presentations; archives (ZIP, gzip, tar, 7z, RAR); data (JSON, XML, YAML); HTML; code; Markdown; calendars; contacts; e-books; SVG; and programs (Windows, Android). Each major type has a default: image, audio, video, text, font and model (STL, STEP). Anything else gets a plain file. The icons take the theme's colour, like the other icons in the app (`typeIcon` in `lib/widgets/attachments.dart`).

### Tenants

*Gone with the tenants (decision 82).* Built with the server's tenants (TENANTS.md, removed with them on 2 November 2026), API revision 11.

56. **One server address per inventory, as before.** The hostname in it picks the tenant, so the login screen, Me and everything else stay as they are; nothing tells users that there are other tenants (your decision). An IP address alone picks no tenant: on a home network, use a name such as `http://bbj.192.168.1.10.nip.io:8080`.
57. **Unit ids are strings** (UUIDs), and quantities and families say whether they are available, the default, and the inventory's own choice.
58. **Manage → Units has a switch for each quantity and family** (model write privilege). A quantity that is off keeps its families' switches off. Once a global one is switched, an undo button returns it to the default, with the default in its tooltip. Turning off what attributes or items use is refused, and the message names them. Others see "Off" where something is off. The arrow that says a quantity or family opens sits on the left, turning as it opens, since the switch takes the right (your find).
59. **Choosing units:** the unit picker offers only units of available families. A number field takes units of available families, and of its own unit's family even when that is off, since its values are already shown in it.

### Model files

60. **Import a model** ([seed/model-format.md](seed/model-format.md)): an Import button on the class tree (model write privilege) puts a model file's classes at the top, and "Import a model here…" in a class's menu puts them below that class. A dry run comes first: the dialog says where the classes go, what would be added (units, attributes, options, classes, assignments), how much is there already, and every conflict. Import is offered only when there is something to add and nothing in the way.
61. **Units come in model files** (API revision 12, [seed/model-format.md](seed/model-format.md), decisions 21–35). Manage → Units → Import imports a model file, with the same dialog as the class tree's Import; for a file without classes it doesn't say where classes go. The dialog takes the file's name from its `meta`.
62. **Export as a model file…** in a class's menu saves the class with everything below it as "CLASS.json": a save dialog in the native apps, a download in the browser, as for attachments. Anyone who sees the class can export it, so read-only accounts get the menu too, with only Export in it. The file is indented, with its keys in the order the server wrote them.

### Keyboard

63. **Dropdowns take keys as select boxes do** (your find): with a dropdown focused, typing picks the next option starting with what was typed (letters within a second add up, "in" for integer; one letter again goes on to the next option with it), and the up and down arrows pick the previous and next option instead of moving to another field. Enter and space still open the menu. Flutter's own dropdown has neither. This is in the attribute type, account privileges and the unit next to a number. Choice and yes/no values have more (your find): their field can be typed into, open or not, and the list narrows to the options with what was typed (ignoring case); the arrows and Enter choose, and the empty entry ("—") clears it so the default applies. A choice can have many options, which a list you can only scroll through doesn't suit. On phones, tapping it brings up the keyboard. Text that isn't an option is refused when saving.
64. **Fields that open a picker take keys too** (your find, on the Items screen's Class): a class, a location, a parent, an item or a unit is chosen in a picker with a search, not in a dropdown, since there can be many and classes and locations are trees. Typing in such a field opens its picker with what was typed already in the search, and the down arrow opens it; Enter and space open it as before. Enter in the picker takes the first match.

### Photos

*Gone with the class photos (decision 75).*

65. **An item without a photo of its own shows its class's** (your choice), or the nearest parent class's that has one, wherever items show a photo: the item screen, search results, a class's items, and a location's stock (after the row's own photo and the item's), as stock rows show their location's. The item's attachments still list only its own, and only its own can be made its photo. The app takes the class photos from the class tree it keeps anyway.

### Desktop

66. **The window opens where it was,** at the same size, maximized if it was (Windows, macOS and Linux; `lib/window_place.dart`, with the `window_manager` and `screen_retriever` packages). Where it is goes into the app's settings (shared_preferences) half a second after it moves or changes size, and when it closes, since Windows only reports moves and resizes made with the mouse. A maximized window keeps the size it had before, for when it is restored. A place no longer on any screen (an unplugged monitor) is centred on the main screen, and a size larger than that becomes the default 1280×720. The Windows runner no longer shows the window by itself (`windows/runner/flutter_window.cpp`): the app shows it once it is in place, so it doesn't appear at the default place first. There are no macOS and Linux projects yet; made with `flutter create --platforms=macos,linux .`, they need the same change to their runner to avoid that jump, and the rest works as it is.

### Importing, in one place

67. **Manage → Import** (model write privilege) is the one place to import a model file, since a file may hold units, attributes, classes or any of them (your idea). The Import buttons on the class tree and the Units screen, and "Import a model here…" in a class's menu, are gone (decisions 33, 60 and 61 described them). The preview says where a file's classes go, the top of the class tree to start with, and Change… chooses a class (or the top) to put them below; the dry run is then done again, since what is there already depends on where they go. A file without classes isn't asked. Export stays in a class's menu, as an export is of one class.

### Classes under Manage

68. **Classes are under Manage,** first in its list, and no longer a destination of their own (your idea): they are what the inventory is set up with, like attributes and units, and they are where an import's classes go. That leaves four destinations: Items, Locations, Manage and Me. Everyone sees Classes, as everyone sees Units; only Attributes needs model read. The class tree and class screens, and their history, belong to Manage in the bar and the rail, and their URLs (`/classes/…`) are as before. Browsing items by class is one tap further away; the Items screen's class field filters by class too.

### Roles: viewers, users and admins

69. **One role per account** (your design; ACCOUNTS.md has the table), in place of the four privileges: users keep the items and stock, admins set the inventory up, viewers look.
    - **Admin** is the new name of Manage (`/admin`), and only admins see it: Items, Locations, Admin and Me for them, Items, Locations and Me for the others. Its screens (classes, attributes, units, accounts), making and changing locations, and the history of anything but items and stock rows send others to Items, even when opened by URL. An item's class isn't a link for them.
    - **Admin → Export** asks which class, and saves it as the class's menu does. Exports are for admins only, as only they can import the file again (your rule).
    - **Users** add, change, delete and restore items and stock rows, with their values and attachments, and put stock in any location; **viewers** get none of those buttons. Everyone sees the history of items and stock rows.
    - **Accounts** have one Role field; a new account is a viewer unless another role is chosen. Your own role can't be changed (the server refuses it), so the field is greyed out for you. Me shows your role.
    - **Old history:** account entries from before roles still read, as "Data privilege: read only → read and write".

### iOS, macOS and Linux

70. **The three projects** (`app/ios/`, `app/macos/`, `app/linux/`), made with `flutter create`, app ID `io.bbj.wtf` and the name "WtF", as on the other platforms. They're built on your own machines over SSH rather than on GitHub: iOS and macOS on the Mac Mini (mercury), Linux on venus.
    - **The window waits for the app** on macOS and Linux too (decision 66): the runners leave it hidden until `lib/window_place.dart` has put it where it was.
    - **macOS** apps run in Apple's sandbox, so the app asks for network access (to reach the server) and for files you choose (attachments, model files).
    - **iOS** says why it wants the camera and the photo library; iOS shows that when asking you, and an app without it is stopped.
    - **Linux** needs `libsecret` to build and the desktop's keyring to run, to keep you logged in.
    - **Real iPhones** came later, with the Apple Developer account (decision 85).
71. **Linux is installed from a `.deb`** (your choice, for now), made on venus by `scripts/build-deb.sh`, for Debian, Ubuntu and their relatives. Without a launcher entry the desktop shows a generic icon and no WtF among the apps, and something has to put that entry in place.
    - **The package** puts the app in `/opt/wtf` (Flutter's bundle wants its `lib/` and `data/` beside it), the launcher entry in `/usr/share/applications/io.bbj.wtf.desktop` (`app/linux/packaging/`) and the logo, as it is, in `/usr/share/icons/hicolor/scalable/apps/io.bbj.wtf.svg`. Both are named after the app ID, which is how the desktop matches the running window to them. Nothing goes in `/usr/bin`, where `wtf` is the command-line tool.
    - **It's called `wtf-app`,** leaving `wtf` for the command-line tool. Its version is the app's (`pubspec.yaml`); the system libraries it needs are worked out by `dpkg-shlibdeps`.
    - **Installing** is `sudo apt install ./wtf-app_<version>_amd64.deb`; updates are a newer `.deb` installed the same way, as there's no package repository.
    - **Later** (TODO.md): a Flatpak, or instructions for building it yourself.

### Attributes in JSON, sessions, and no tenants

Built for the API as the plan of 2 November 2026 left it ([2026-11-02-attributes-in-json.md](2026-11-02-attributes-in-json.md); the reminders are in [2026-10-31-changes-to-the-apps.md](2026-10-31-changes-to-the-apps.md)), with the plan of 1 November 2026 ([2026-11-01-dropping-deleted-and-history.md](2026-11-01-dropping-deleted-and-history.md)). The API's revision started again at 1.

72. **A class's attributes are on its screen,** under Item attributes and Stock attributes, its own and those it inherits. Admin → Attributes and its screens are gone.
    - **Adding one** asks for its name, its type, whether its values are on the item or on each stock row, a unit (numbers), the choices (a choice: one per line, or separated by commas), the file types it takes (a file: `application/pdf, image/*`, empty for any), a default, and whether it is required. Types are shown in words: text, integer, number, date, yes or no, link, choice, file.
    - **Changing one** it defines (a tap, or Edit… in its menu) changes required, the unit, the default, the file types and its order. Its type and where its values live are shown, not offered: they never change. Its menu also has **Rename…**, **Choices…** (a choice: add, rename and remove them) and **Remove…**.
    - **An inherited one** says which class it comes from; a tap opens that class, where it is changed.
    - **Every change says what it does first:** the app sends it as a dry run, shows what it would rewrite ("This rewrites 1,204 items.", or "No item or stock row changes."), and sends it for real only when you agree. A refusal (a choice still in use, a required attribute without a default while items lack it) is shown at once, from the dry run.
    - **Names** can't be those of the fields every item or stock row has (`name`, `class`, `unit`, `photo`, `amount`, `reference`, `serial`, …); the form says so before anything is sent.
73. **Values are by name, and an item or a stock row is saved in one request:** its fields and its changed values together, `null` removing a value.
    - **A value that follows the class's default** says so: "(default)" after it on the item, and "The class's default" under its field in the form.
    - **Back to the default:** a button in the field, when the attribute has a default and the value doesn't follow it, gives the value its default back and makes it follow the default again.
    - **Moving an item to another class** says which of its values that class has no attribute for; saving removes them, as the server would otherwise refuse the move.
74. **Units are labels.** An attribute's unit shows after its numbers, in fields too; a number is typed without it, or with it (`12 mm`), and another label is refused, as nothing converts. An item's "Unit of its stock" is a text field ("m"; empty: pieces, counted one by one, whose amounts are whole). The unit menu next to number fields, the unit picker, Unit lock and Admin → Units are gone, and so are decisions 1, 25–27, 33 and 57–59.
75. **Files are photos and attachment attributes.**
    - **An item and a stock row have a photo:** **Photo…** in their menu chooses an image (or takes one, on a phone), another one, or removes it. It shows as before (decisions 39, 40 and 48). Its address carries the file's hash, so a new photo is never shown from an old copy.
    - **An attachment attribute** is listed under Files on its item or stock row: with a file, a tap opens it, and its menu has Open, Save…, Replace… and Remove…; without one, a tap uploads one, and it says which types it takes. Viewers see only the files there are. Files aren't part of the forms: they are uploaded on the item's or stock row's screen.
    - **Opening:** the web app opens the file's address in a new tab, as before. The native apps learn a file's type only from the download; they open the types of decision 54 with the device's app, and save anything else instead. The file is named as the server names it, after the attribute ("Datasheet.pdf").
    - **What is gone:** attachments of their own, their titles, the attachment screen, and the photos of classes and locations (decisions 34–38, 41, 45 in part, and 65).
76. **Stock rows have a reference and a serial number,** in the stock form, on the stock row's screen, and after the code in lists of stock rows ("ref PO-12 · serial 4711"). Amounts are called amounts.
77. **Merging is an action of its own:** **Merge into…** in a counted stock row's menu, as a move never merges. It lists the item's other counted rows, takes an amount (empty: all of it), and, where the two rows differ (reference, serial, photo, or a value), shows both rows' values side by side, to pick which to keep for each; the other row's is picked to start with. The app finds the differences as the server does, so the merge is sent once, with what to keep.
78. **Lists come a page at a time, by key,** and give no count: the results' title is "Found items", and the next page is asked for with the last one's key as the list scrolls. A class shows its first 100 items, and "More…" opens the search for its class; a location its first 1000 stock rows, and says when there are more.
79. **Sessions.**
    - **Logging in** asks how long to stay logged in while unused: a day, a week, 30 days (the default), a year, or until you log out. The app tells the server what it is: "WtF on DESKTOP-PC (Windows)", "WtF on Android" where the device's name tells nothing, "WtF in a browser".
    - **Me lists your sessions,** most recently used first: what each is, when and from where it was last used, when it was logged in, and when it ends unless used. Each can be logged out, this one too, and **Log out everywhere else** ends all the others.
    - **A new password** logs your other devices out, unless you untick "Log out my other devices". An admin setting or removing someone's password chooses "Log the user out everywhere", ticked to start with when the password is removed. An admin's own password is changed under Me.
80. **Deleting removes, and says so first:** every delete asks, with "This can't be undone." A deleted thing's label code (410) says "This label's item, stock row or location has been deleted", in search and on the screens for codes; a code never handed out finds nothing, as before. History, restoring and the deleted banners are gone (decisions 23, 24 and 37).
81. **A model import's preview** says how many classes and attributes it adds, how many are there already, and how many items and stock rows already there get a default. A file that can't be imported is refused by the dry run, with the server's reason.
82. **No tenants:** a server is one installation, and nothing in the app knows about tenants.
83. **Tests:** 55 in all. Unit tests: what people type (numbers with their unit's label, values by type, conditions, dates, codes, grids), the client (cookies, error messages, a changed tree, the calls against `openapi/openapi.json`) and a choice field. Widget tests run the whole app against a pretend `wtfd` (`test/fake_server.dart`): logging in for a while, sessions and passwords, Admin, a class's attributes with their dry runs, choices, values by name with Back to the default, a photo and a file attribute, reference and serial, moving and merging, paging by key, search with filters by name, a deleted thing's label, deleting, and the roles.
84. **The desktop app's program is `wtf-app`** on Windows and Linux (`BINARY_NAME`, and on Windows the file names in `Runner.rc`), so that it never clashes with `wtf`, the command-line tool: Windows ignores case in file names, so the two `wtf.exe` couldn't share a folder, and whichever came first on the PATH won. People start the app by its display name, "WtF", which stays everywhere: the window title, the Start menu, the launcher entry, the program's properties. On Linux the package was `wtf-app` already (decision 71); the app is now `/opt/wtf/wtf-app`. macOS keeps `WtF.app`, which clashes with nothing.
85. **The iOS app runs on real iPhones,** signed for development with your Apple Developer team (`GK5LDQD7GU`, in the Xcode project) and Xcode's automatic signing, and built and installed on mercury over SSH by `scripts/ios-device.sh` (see BUILDING.md).
    - **A release build,** since a debug build on a device only starts from the debugger.
    - **Its own keychain:** over SSH, the login keychain stays locked, so `scripts/ios-signing-setup.sh` moves the signing certificate and its key to a `wtf-signing` keychain with a random password in a file on the Mac, which the build unlocks.
    - **Installing, not starting:** the script installs the app; you start it.
    - **Over Wi-Fi:** once paired by cable, the phone is reached over the network, so later installs need no cable.
    - **Not yet:** TestFlight and the App Store.
86. **Me is called Account** (your choice): in the bar and the rail, and as the screen's title. What it shows is as before (your account, the server, your role, the appearance, your password, your sessions); the line with your email address is labelled Email rather than Account, as that is now the screen's name. Its address in the web app stays `/me`, as does the API's `GET /me`. The decisions above that say "Me" mean this screen.
87. **A System look,** the new default, next to Teal and Orange (your idea and choices): close to the platform's own apps rather than Material's, which looked alien there. Teal and Orange stay as they were, and so does a device where one of them was chosen.
    - **Why Material looked alien:** backgrounds, bars and cards tinted with the theme's colour, pill-shaped buttons and tab highlights, very round dialogs, ripples where you tap, and Material's text sizes.
    - **iPhone, iPad and Mac:** iOS blue as the one accent, white (or black) pages with light grey bars and groups, titles in the middle of the top bar, a bottom bar like iOS's tab bar (the selected tab in blue, nothing behind it), San Francisco at Apple's sizes, corners of 10 and 14 points, filled grey text fields. Confirmations are Apple's own alerts, and switches Apple's own.
    - **Windows:** Windows 11's default accent blue, a light grey page with white cards and fields with a line around them, corners of 4 and 8 pixels, Segoe UI at 14 points.
    - **Linux:** GNOME's Adwaita: its blue, titles in the middle, grey fields, corners of 6 and 12 pixels.
    - **Android:** Material as it is, which is Android's own look. The wallpaper's colours (Material You) would need the `dynamic_color` package, a new dependency; not for now.
    - **Everywhere but Android:** no ripples, and surfaces without the accent's tint.
    - **How:** one theme per platform in `lib/theme.dart`, built from Material's widgets, as the screens are the same everywhere; no Cupertino or Fluent widget sets, which would mean building every screen twice. The web app takes the look of the device the browser runs on. The accents are fixed per platform, not the one chosen in the system's settings. The forms' outlined text fields take the System look's borders.
    - **Tests:** 56, with one for the System look on each platform.
