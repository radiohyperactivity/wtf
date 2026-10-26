# WtF apps – design

**Status: agreed, not built yet.** The decisions taken in review are listed at the end.

The apps are one Flutter program for every platform: web, Windows, macOS, Linux, Android (phones, tablets and Chromebooks) and iOS/iPadOS. Flutter is Google's toolkit for building apps from one codebase. Its programs are written in Dart, a typed language that resembles Go, Java and JavaScript.

## The first version

It covers what you do every day. The CLI covers the rest until the apps catch up.

| In the first version | Later |
|----------------------|-------|
| Log in and out, change your password | Managing classes, attributes, options and accounts |
| Search, and browse the location and class trees | History |
| Look at an item: values, stock and where it is, photos | Uploading photos and attachments |
| Add items (with their values), stock and locations (also with a compartment grid) | Label scanning |
| Move stock, and edit items and stock rows | |

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
  - The **web app** uses its own address, because `wtfd` serves it from the tenant's hostname, so there's nothing to enter.
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
| `/` | Search: one search field, with the found items and where they are, like `wtf find`. The start screen. |
| `/locations` | The location tree. Containers are marked, and grids show their compartments. |
| `/locations/1A7K` | A location: its path, what's below it, the stock at it, and its photos. |
| `/locations/new?parent=…` | Add a location, optionally with a compartment grid (`8 × 5`). |
| `/classes` | The class tree. |
| `/classes/<id>` | A class: its attributes and its items. |
| `/items/1B2C` | An item: values, stock rows with their locations, photos. |
| `/items/new?class=…` | Add an item: class, name, then its attributes (required ones first). Afterwards it offers to add stock, like the CLI. |
| `/items/1B2C/edit` | Edit an item: name, class, values. |
| `/stock/1C3D` | A stock row: quantity, location, per-unit values; move it (all or part), or edit it. |
| `/me` | Your account: email, privileges, change password, log out. |

**Choosing things:** wherever a location or class must be chosen, a picker with search and the tree replaces the CLI's typing with Tab. Units work as in the CLI: you can type `12mm` or `2.5 m` into a number field, and the app converts and checks it as you type, with the same rules as the CLI (decision 1).

## Layout: one design for every screen size

Flutter has standard size classes, measured in logical pixels, which are independent of the screen's resolution:

| Width | Typical device | Navigation | Content |
|-------|----------------|------------|---------|
| under 600 | phone | bar at the bottom: Search, Locations, Classes, Me | one screen at a time |
| 600–840 | small tablet, phone sideways | rail on the left | list and details side by side where it fits |
| over 840 | tablet, desktop, browser | rail on the left | list and details side by side, the tree always visible |

- **Look:** Material 3, Google's current design system, which Flutter has built in. Light and dark follow the system setting.
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
