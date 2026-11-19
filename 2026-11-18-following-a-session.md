# Following a session – plan

**Status: replaced (2026-11-19)** by [the phone as a remote camera](2026-11-19-remote-camera.md), before it was released: on the phone, the event stream it depended on closes whenever the screen locks. Kept as a record.

## Why

Items and stock are best entered at a computer, but photos are best taken with a phone. With this, the phone **follows** a session of the same account, say the Windows app: it shows the item, stock row or location that session shows. You save a new item on the PC, pick up the phone, and it shows that item with a large "Take photo" button. The photo appears on the PC by itself.

## How it works

1. **On the phone, you choose whom to follow,** from your account's active sessions under Account (decision 1). The phone remembers the choice, and tells the server again each time it connects.
2. **Every app says which screen it shows,** when it shows an item, a stock row or a location: `PUT /me/view {"route": "/items/1B2C"}`. The server keeps the route only for a session that someone follows, and passes it on to its followers; for any other session it is thrown away.
3. **Every app listens** to a stream of events from the server, `GET /me/events`, while it is in the foreground:
   - `view`: the session it follows shows another screen, or, at once when it connects, the screen that session showed last;
   - `changed`: the session it follows, or one that follows it, changed something (a photo uploaded, say); the screen showing data loads again;
   - `unfollowed`: the session it follows has logged out;
   - `ended`: its own session has ended.
4. **The phone goes to the route,** unless you are busy on it: in a form, a dialog or taking a photo. Then it goes there once you're done.

## Decisions

### What it does

1. **You choose whom to follow** from the list of your account's active sessions, under Account *(yours)*. Only your own account's sessions can be followed, and not the session you follow from.
2. **On an item or a stock row, the phone shows a large "Take photo" button** while following *(yours)*. It opens the camera at once, and uploads the photo as the photo of that item or stock row.
3. **A change made by one side reloads the other side's screen** *(yours)*: when the phone uploads a photo, the PC's item screen shows it, without you doing anything.
4. **A reload never loses what you've typed** *(yours)*. Only screens that show data are loaded again: the item, stock row and location screens, and the location tree. Forms are never loaded again under you, and dialogs keep their own state. A form saves only the fields you changed, so a photo uploaded meanwhile from the phone stays.
5. **Followed screens:** an item, a stock row and a location (`/items/<code>`, `/stock/<code>`, `/locations/<code>`). The forms, search results and Admin aren't followed: the phone stays where it is. So when the PC goes from the new item on to "Add stock", the phone stays on the item, where the photo is taken.
6. **The phone doesn't move while you're busy on it:** in a form (a route ending in `/new` or `/edit`), while a dialog, menu or bottom sheet is open, or while a photo is being taken and uploaded. The latest route it was told is kept, and it goes there once you're done.
7. **While following, a bar shows whom,** "Following WtF on Windows", with **Stop**, on every screen.
8. **Every app reports its screens and listens,** phones and desktops alike, so any session can be followed and get changes. A desktop could follow another desktop.

### In the server

9. **Nothing in the database** *(yours)*. The follows, and the latest route of a followed session, are kept in `wtfd`'s memory. A restart forgets them all. The phone then registers its follow again when it reconnects, and shows the next screen the PC shows.
10. **Only followed sessions' routes are kept** *(yours)*: memory grows with the follows, not with the sessions. A session's route is dropped once nobody follows it.
11. **A follow outlives the phone's connection.** Phones close connections in the background; the server keeps the follow, and the latest route, so the phone gets it when it comes back.
12. **A follow ends** when the phone stops following, follows another session, or logs out; when the followed session logs out (`POST /logout`, or `DELETE /me/sessions/{id}`); when either session is found ended (decision 15); and when the phone hasn't been connected for 12 hours. Old follows are cleared when the follows are next used, at most every 10 minutes, without a timer of its own.
13. **The cookie proves the session without the database.** A session's id is the SHA-256 of its token. Only the holder of the token can send a request whose cookie hashes to the id of a followed session, so `PUT /me/view` and `DELETE /me/following` don't touch the database. A view from a session nobody follows is thrown away, with the same 204, so the answer says nothing about follows.
14. **Starting a follow asks the database once:** `account.session_follow`, which checks that both sessions are active and of the same account, and gives the followed session's client name. A new function in a repeatable script, so no migration.
15. **The event stream asks the database when it opens, and every 5 minutes:** whether the session is still valid (`account.me`). A session that ended meanwhile (logged out from another device, a password change, an account deleted) gets `ended`, and its follows are dropped. The rest of the time the stream doesn't touch the database.
16. **Server-sent events** (`text/event-stream`): a plain HTTP request that stays open, which works in the browser and through nginx. WebSockets would also allow the other direction, which isn't needed.
17. **Long-lived streams:** `wtfd` ends every answer after 60 seconds (its write timeout). The event stream lifts that for its own answer only, and sends a comment line every 30 seconds, so proxies and phones don't drop a quiet connection. `wtfd` ends the streams when it shuts down.
18. **`changed` events** are sent after each successful change by a session that follows, or is followed: any request other than GET under `/items`, `/stock` and `/locations`, uploads included. The event gives the request's path. A session that neither follows nor is followed costs one map lookup.
19. **One `wtfd` per database.** The follows live in one server's memory. That is how WtF is set up already; WTFD.md says so.

### In the apps

20. **The phone tells the server whom it follows each time it connects,** before opening the stream (`PUT /me/following`). That also covers a restart of `wtfd`. A follow refused because the session has ended is forgotten, with a message.
21. **The stream is open while the app is in the foreground,** and reconnects after an error, waiting 2, 5, 15 and then 30 seconds. On a phone, it closes in the background and opens again when the app comes back.
22. **The web app reads the stream like the others:** `package:http` streams answers in the browser too (it uses `fetch`).

## The API

| Route | Does | Database |
|-------|------|----------|
| `PUT /me/following` `{"session": "<id>"}` | Follow that session, replacing a follow there was. Answers `{"session", "client"}`. 404 when it isn't one of your account's active sessions, 400 when it is the session itself. | `account.session_follow` |
| `DELETE /me/following` | Stop following. 204, also when there was no follow. | – |
| `PUT /me/view` `{"route": "/items/1B2C"}` | The screen this session shows. 204. A route is a path of the app, at most 500 characters. | – |
| `GET /me/events` | The event stream (`text/event-stream`): `view` `{"route", "client"}`, `changed` `{"path"}`, `unfollowed` `{}`, `ended` `{}`. | `account.me` when it opens, and every 5 minutes |

## Steps

1. This plan.
2. The server: the follows in memory, the four routes, `account.session_follow`, the `changed` events, ending the streams on shutdown; unit tests of the follows, and an integration test with a real stream.
3. The apps: reporting the screen, the event stream, following from Account, the bar, going to the route when not busy, reloading on `changed`, the "Take photo" button; widget tests against the pretend server.
4. The documents: API.md, WTFD.md, the OpenAPI description, PROXY.md (nginx must pass the stream on as it comes), APP.md.
