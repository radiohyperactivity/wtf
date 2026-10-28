# WtF apps – design

**Status: the first version is built for web and Windows, not yet reviewed.** The decisions taken in review, and the ones I took while building, are listed at the end.

The apps are one Flutter program for every platform: web, Windows, macOS, Linux, Android (phones, tablets and Chromebooks) and iOS/iPadOS. Flutter is Google's toolkit for building apps from one codebase. Its programs are written in Dart, a typed language that resembles Go, Java and JavaScript.

## The first version

It was planned to cover what you do every day. While building it, it grew to cover almost all of the CLI (decision 5). The CLI covers the rest.

| In the first version | Later |
|----------------------|-------|
| Log in and out, change your password | |
| Search, and browse the location and class trees | Label scanning |
| Look at an item: values, stock and where it is, photos | |
| Add items (with their values), stock and locations (also with a compartment grid) | |
| Move stock, and edit and delete items and stock rows | |
| Manage classes (with their attributes), locations, attributes and their options, and accounts | |
| History, and the units | |
| Titles of attachments, the item photo (class photo, …), removing attachments | |
| Uploading and downloading files, taking photos (phones), restoring attachments | |

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
- **Names:** "Where the Fxxx" in the stores. Under the icon on a home screen, the shorter "WtF" fits better.

## Talking to the API

A small hand-written Dart client, the counterpart of the CLI's Go client (`internal/client`):

- **One method per API call:** for example `items.get(code)` or `stock.move(id, location, quantity)`, returning Dart classes such as `Item` and `Stock`.
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
- **A test keeps it honest:** it reads `openapi/openapi.yaml` and checks that every path the client uses exists there, like the server's route test.

## Screens and URLs

Every screen has a URL. In the web app it shows in the address bar, and it works as a link, a bookmark and after a reload (`wtfd` answers app URLs with `index.html`). Items, stock rows and locations use their label codes, which are short and printed on labels anyway. Classes have no codes, so they use their ids.

| URL | Screen |
|-----|--------|
| `/login` | Log in. The native apps also ask for the server address. |
| `/` | Items: the search form (words, a class, and its attributes), like `wtf find`. The start screen. |
| `/found?search=&class=&where=` | The items found, and where they are. Opened by the form, on top of it. |
| `/locations` | The location tree. Containers are marked, and grids show their compartments. |
| `/locations/1A7K` | A location: its path, what's below it, the stock at it and further in, and its photos. Edit, add a location inside, delete (with everything below it). |
| `/locations/new?parent=…` | Add a location, optionally with a compartment grid (`8 × 5`). |
| `/locations/1A7K/edit` | Edit a location: name, parent, container. |
| `/classes` | The class tree. |
| `/classes/<id>` | A class: its attributes (assign, change, remove), the classes below it and its items. Edit, add a class below, delete. |
| `/classes/new?parent=…`, `/classes/<id>/edit` | Add or edit a class: name, parent, container. |
| `/items/1B2C` | An item: its details and values, its photo, stock rows with their locations, attachments. A stock row's code shows its item too, as in the CLI. |
| `/items/new?class=…` | Add an item: class, name, then its attributes (required ones first). Afterwards it offers to add stock, like the CLI. |
| `/items/1B2C/edit` | Edit an item: name, class, unit and Unit lock, values. |
| `/stock/1C3D` | A stock row: quantity, location, per-unit values; move it (all or part), edit or delete it. |
| `/stock/new?item=…&location=…` | Add stock: item, location, quantity, per-unit values. |
| `/stock/1C3D/edit` | Edit a stock row: location, quantity, per-unit values. |
| `/history/<kind>/<id>` | The history of an item, stock row, location, class, attribute or account, in words, by day (decision 23). |
| `/history/<kind>` | The history of the top level of the locations or classes, or of the list of attributes: what was added, moved to or from the top level, deleted or restored. The History button on the tree and on Attributes opens it. |
| `/me` | Your account: email, privileges, appearance (light, dark or as the system), change password, log out. |
| `/manage` | Links to attributes, units and accounts. |
| `/attributes`, `/attributes/<id>` | The attributes; one attribute with its options (add, rename, delete). |
| `/accounts`, `/accounts/<id>` | The accounts: email, privileges, password (keep, set or remove). |
| `/units` | The units by quantity and family, for reference; Import adds more from a unit file. |

**Choosing things:** wherever a location or class must be chosen, a picker with search and the tree replaces the CLI's typing with Tab. Units work as in the CLI: you can type `12mm` or `2.5 m` into a number field, and the app converts and checks it as you type, with the same rules as the CLI (decision 1).

## Layout: one design for every screen size

Flutter has standard size classes, measured in logical pixels, which are independent of the screen's resolution:

| Width | Typical device | Navigation | Content |
|-------|----------------|------------|---------|
| under 600 | phone | bar at the bottom: Items, Locations, Classes, Manage, Me | one screen at a time |
| 600–840 | small tablet, phone sideways | rail on the left | list and details side by side where it fits |
| over 840 | tablet, desktop, browser | rail on the left | list and details side by side, the tree always visible |

- **Look:** Material 3, Google's current design system, which Flutter has built in. Light and dark follow the system setting, unless you choose one on the Me screen (decision 6).
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

1. **Numbers with units are converted by each client, for now.** The API keeps taking numbers in the base unit of the quantity, as before. Each client turns `12mm` into `0.012` itself and checks it while you type, so mistakes are caught at once. The CLI does this today (`internal/cli/units.go`), and the apps get the same rules in Dart. Doing it on the server was tried, and set aside because prompts and forms could then only report mistakes when saving.
2. **No `--dev-origin` for now.** Development uses the Windows app, which needs nothing on the server, and the web app is tested through `--web-root`. The switch can come later if web development without hot reload becomes a nuisance.
3. **The start screen is search.**
4. **The name under the icon is "WtF".** If the stores object to "Where the Fxxx", WtF can also stand for "Where to Find".

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
11. **Forms save at the end, as the CLI's edit forms do.**
    - **What is sent:** only what changed, in several requests if needed (the item, then each value).
    - **When a request fails:** the message lists what was already saved ("Already saved: name").
    - **Values:** clearing one removes it, so the class default applies again. A required value without a default can't be cleared.
    - **Existing values:** they appear as shown elsewhere (`18 V`, `32 KiB`), which reads back to the same number. So saving without changes sends nothing.
12. **New items.**
    - **Stock afterwards:** as in the CLI (decision 43), the app asks once "Add stock for …?". Yes opens the stock form, and the item's screen follows.
    - **Units:** a new item can have any unit, or pieces. An existing item can only change to another unit of the same quantity, and only if it has one (CLI decision 41).
13. **Moving stock.**
    - **How much:** an empty quantity moves all of it. Uncounted rows can only move whole, so they get no quantity field.
    - **What you see afterwards:** the server answers with the row at the destination, which may be the same row, a new one split off, or one it was merged into. The app shows that row.
14. **Grids.**
    - **The form:** two fields, columns and rows, with a preview ("40 compartments, A1 … H5").
    - **Big grids:** over 1000 locations, the app asks first and then sends `confirm`, as the server requires.
    - **Parents:** missing parents aren't created (decision 5).
15. **Privileges.** Buttons for changes the account may not make are hidden: data write for items, stock and locations, model write for classes and attributes, account write for accounts. The server checks anyway. (Locations were first wrongly tied to model write; fixed with decision 24.)
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

Added after review, with the deletion design ([api/deleting.md](api/deleting.md)).

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

Built for API revision 3, with the server's change to units (CLI.md decision 48).

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
    - **Wide:** a table with the item, its class, stock and locations, and a column for every attribute the found items have values for. Only the items' own values: per-unit ones belong to stock rows, and are shown on the item and the stock row (your choice, after a long per-unit value stretched rows). Each cell ends after three lines, the rest in a tooltip. Columns appear in the order they are first seen, so they don't move as more rows load. Class defaults are shown in grey italics. The table scrolls sideways when it doesn't fit.

### Importing units

Built for API revision 5, with unit files ([seed/units-format.md](seed/units-format.md)) and `POST /units/import`. Made while you were away; see the decisions to discuss there.

33. **Import on the Units screen,** for accounts with the model write privilege, like `wtf unit import`.
    - **Choosing the file** uses the `file_picker` package, a new dependency. It works on the web, Windows, Android and iOS, and the Windows and web builds succeed with it. If you'd rather not depend on it, pasting the JSON into a text box would do instead.
    - **A preview comes first** (a dry run): what the file adds, by quantity, family and unit, and how much of it is there already. Import then imports it, and the screen shows the new units at once.
    - **Conflicts** are listed with where they are and why, and then there's only Close: nothing is imported until the file is fixed.
    - **The file is sent as it was chosen,** so factors keep every digit.
    - **A file that isn't a unit file** is refused with the server's reason, such as a missing key or a newer version.

### Attachments, redone

Built for API revision 7, with the new attachment model ([api/attachment.md](api/attachment.md)).
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
41. **One list of attachments.** Images show their small version where other files show a paperclip, so titles line up; tapping either opens the attachment screen, and tapping the small image opens it full size. The photo's line says "Item photo" (class photo, …) before its type and size, instead of a star. Other file types can get their own icons later (`attachmentIcon`).
42. **A thin border around photos,** small and large, in the theme's outline colour, so a photo whose background is just off the app's doesn't look misplaced.
43. **An item's values are details,** right under Code, Class and Stock in, without a "Values" heading. Stock rows keep the heading, since their own details (item, location, quantity) are of another kind.
44. **Buttons in a section heading take at most half its width** and wrap onto a second line, so Take a photo and Add files fit on a phone.

### Photos in the trees, and framed icons

Built for API revision 9: the class and location tree nodes include their `photo` ([api/attachment.md](api/attachment.md)). Revision 10 adds the stock row's `photo` to stock lists and the item's `photo` to item summaries, such as the item of a stock row.

45. **A photo or a framed icon** at the start of every list entry for an object: the object's small photo, or, when it has none, its icon in a frame the same size. That covers attachments (the paperclip), items (narrow list, wide table, a class's items), an item's stock rows (the row's own photo, else its location's), a location's stock (the row's own photo, else its item's), what's inside a location, the classes below a class, and both trees. The frame is the same thin border as the photos', so entries with and without a photo look alike and their names line up.
46. **The trees use a smaller size,** 36 pixels instead of 48, so they stay compact. Their rows are 48 pixels high instead of 44.

### App icons

47. **The icons come from [logo/](logo/):** the square icon (`icon.svg`) for the app, not the horizontal or stacked logos.
    - **Web:** `favicon.ico` (16, 32 and 48), with `favicon.svg` for browsers that take SVG; `icon-192.png` and `icon-512.png` in the manifest; `apple-touch-icon.png` for iOS home screens. The manifest's and the page's theme colour is the logo's orange, `#ff7828`.
    - **Maskable icons** (Android crops them to its own shape) come from `logo/icon-maskable.svg`: the same stack, smaller, on a full orange square, so nothing is cut off.
    - **Windows:** `app_icon.ico` holds the favicon PNGs at 16, 32 and 48 pixels, and `icon.svg` rendered at 64, 128 and 256 (with headless Chrome).

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
