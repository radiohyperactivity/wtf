# The phone as a remote camera – plan

**Status: built (2026-11-19): steps 1–5.** Still to try on the real devices. It replaces following a session (2026-11-18-following-a-session.md), which was built but wasn't reliable enough on the phone.

## Why

Items and stock are best entered at a computer, but photos are best taken with a phone. With this, the phone becomes a **camera for a desktop session**: you open an item on the PC, pick up the phone, press the shutter, and the photo becomes the photo of that item. The PC shows it by itself.

Following a session made the phone show the PC's screen. That needed an event stream open on the phone, and phones close it whenever the screen locks, which is just before you pick the phone up to take a photo. Here the phone only takes photos, and it needs no stream: every step on the phone is a plain request, sent when it is needed.

## How it works

1. **On the phone, you choose a desktop session to be the camera for,** from your account's active sessions under Account. The phone remembers it, and opens in camera mode from then on.
2. **The desktop app says what it has open** whenever that changes: an item, a stock row or a location, or a new one not saved yet. The server keeps it only for a session that has a camera.
3. **The phone asks what the photo would be for** when it opens, when it comes back from a locked screen, and every few seconds while it is in camera mode in the foreground, and shows it: "Drill (item)".
4. **The phone uploads the photo to the desktop session, not to an item.** The server attaches it to what the desktop has open at that moment, and answers what it was for. So a target shown a moment late on the phone never puts a photo in the wrong place.
5. **The desktop gets `changed`** on its event stream, and loads the screen again, keeping what you've typed.

## Decisions

### What it does

1. **You choose the desktop session** from the list of your account's active sessions, under Account. Only your own account's sessions, and not the phone's own session.
2. **Camera mode** is a screen of its own on the phone: what the photo is for, a large shutter button, the last photo taken with what it went to ("Added to Drill"), and **Stop** to leave camera mode. The phone stays in camera mode until you stop it, also after the app is closed and opened again.
3. **One photo per item, stock row and location** *(yours)*. A new photo replaces the one there was.
4. **Locations get a photo** *(yours)*, as items and stock rows have: a new column, its upload route, and the photo on the location screen, set from its menu as for items, by admins only *(yours)*. A stock row without a photo of its own shows its location's in the item's list of stock rows *(yours)*.
5. **What a photo can be for:** an item, a stock row or a location that the desktop shows, or edits in its form.
6. **A new item, stock row or location that isn't saved yet:** the shutter is off, and the phone says "Save the item on the PC first" *(yours)* (or the stock row, or the location).
7. **Nothing open on the desktop** that a photo can be for (a list, a search, Admin): the shutter is off, and the phone says "Open an item on the PC" *(yours)*.
8. **The desktop doesn't lose what you've typed** when the photo arrives. The item, stock row and location screens load again; forms don't, and have no photo of their own (it is set from the screen's menu). A form saves only the fields you changed, so it doesn't undo the photo.
9. **The desktop shows that it has a camera,** "Camera: WtF on iPhone", so you know photos will arrive.

### In the server

10. **Nothing in the database** for the cameras: which phone is the camera for which desktop session, and what that desktop has open, are kept in `wtfd`'s memory, as for following.
11. **Only a desktop with a camera has its target kept.** Memory grows with the cameras, not with the sessions. When a phone becomes a desktop's camera, the desktop is told on its event stream (`camera`), and says what it has open; until then the server throws its reports away.
12. **The server decides where a photo goes,** when it arrives: it uploads it as the photo of the desktop's target, through the same functions as the upload routes, as the phone's session. No target: 409, with the message of decision 6 or 7.
13. **A `wtfd` restart forgets the cameras.** The phone says again which desktop it is the camera for, with every request, so nothing is lost: the server makes it the camera again, and tells the desktop, which says what it has open.
14. **A camera ends** when the phone stops it, or logs out; when the desktop session logs out, or is found ended (the phone is told so on its next request, and leaves camera mode with a message); and when the phone hasn't asked for 12 hours.
15. **The cookie proves the session without the database,** as for following: asking for the target, and the desktop's reports, don't touch the database. Becoming a camera asks the database once (`account.session_camera`, which was `account.session_follow`). Uploading a photo is an ordinary change.
16. **The desktop's event stream stays,** with `changed`, `ended` and the new `camera` event; `view` and `unfollowed` go. The phone has no event stream.

### In the apps

17. **The phone asks for the target** with a plain request: when camera mode opens, when the app comes back to the foreground, and every 3 seconds while camera mode is in the foreground. An error shows "Can't reach the server", and the next try comes as usual.
18. **A failed upload can be sent again,** with the photo kept on the phone until it has gone.
19. **Following goes:** the phone no longer shows the desktop's screens, and the "Take photo" button on the item and stock screens goes with it. Picking a photo or taking one on the phone itself stays as it was.

## The API

| Route | Does | Database |
|-------|------|----------|
| `PUT /me/camera` `{"session": "<id>"}` | Become the camera for that session. Answers `{"session", "client"}`. 404 when it isn't one of your account's active sessions, 400 when it is the session itself. | `account.session_camera` |
| `DELETE /me/camera` | Stop being a camera. 204, also when it wasn't one. | – |
| `GET /me/camera?session=<id>` | What a photo would be for: `{"type": "item" \| "stock" \| "location", "id", "name"}`, `{"waiting": "item" \| "stock" \| "location"}` for one not saved yet, or `{}`. Makes the phone the camera again when the server has forgotten it. 404 when that session has ended. | `account.session_camera` only after a restart |
| `PUT /me/camera/photo?session=<id>` | Upload the photo, as the photo of the desktop's target. Answers the target, as above. 409 without one. | The photo upload |
| `PUT /me/target` `{"type", "id", "name"}`, `{"waiting": …}` or `{}` | What this desktop has open. 204. | – |
| `GET /me/events` | The desktop's event stream: `camera` `{"client"}` (a phone became its camera; `{}` when it stopped), `changed` `{"path"}`, `ended` `{}`. | `account.me` when it opens, and every 5 minutes |
| `PUT /locations/{id}/photo`, `GET /locations/{id}/photo` | A location's photo, as for items and stock rows; `PATCH` photo `null` removes it. | `location` |

## Steps

1. This plan.
2. Photos for locations: a migration adding `location.photo`, the routes, the attachment bookkeeping, the location screen and form; tests.
3. The server: the cameras and the targets in memory, the routes above, renaming `account.session_follow`, the `camera` event; dropping the views and `unfollowed`; unit tests, and an integration test.
4. The apps: camera mode on the phone, choosing the desktop under Account, reporting the target from the desktop, "Camera: …" on the desktop, the edit forms taking the new photo; dropping following; widget tests against the pretend server.
5. The documents: API.md, WTFD.md, the OpenAPI description, APP.md; following's plan marked as replaced.
