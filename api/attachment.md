# Attachments

The SQL is in [`db/repeatable/80_attachment.sql`](../db/repeatable/80_attachment.sql), and the tables are in [`db/migrations/0005_attachments.sql`](../db/migrations/0005_attachments.sql) and [`0006_attachment_deleted.sql`](../db/migrations/0006_attachment_deleted.sql). The file handling is in [`internal/files`](../internal/files/), and the upload and download handlers are in [`internal/serve/attachments.go`](../internal/serve/attachments.go).

Files (photos, datasheets, manuals, receipts, …) can be attached to items, stock rows, locations and classes. Any file type is accepted.

## The model

- **Each kind of object has attachments of its own,** in `item_attachment`, `stock_attachment`, `location_attachment` and `class_attachment`. A row is one attachment: `id`, its object (`item`, `stock`, `location` or `class`), `type` (the MIME type), `hash` (the hex SHA-256 of the content), `size` (in bytes), `title` and `deleted`. The title is given at upload, and defaults to the uploaded file's name. Nothing is shared between objects.
- **An attachment is only reached through its object:** `/items/{id}/attachments/{attachment}`, and so on. The same id under another object is not found.
- **A photo:** items, stock rows, locations and classes each have a `photo` column, naming one of their own attachments (a foreign key on the object and the attachment) that must be an image (`image/*`) and not deleted (a trigger). Deleting that attachment clears the photo, for good: restoring it doesn't make it the photo again.
- **Content on disk:** the contents live in `wtfd`'s files directory (`--files-directory`), named by their hash: `<directory>/ab/abcdef…`. A stored file never changes. The same content is stored once on disk, however many attachments have it, on whatever objects.
- **Deleting** an attachment marks it `deleted`, as for items and the rest (see [deleting.md](deleting.md)). It is no longer listed, but can still be fetched, downloaded and restored; it is frozen until then. `wtfd deleted purge` removes it for good by age, and then `wtfd gc` removes its file, once no attachment of any kind has its hash (see [WTFD.md](../WTFD.md)). Deleted attachments are found again through history.
- **Deleted objects keep their attachments,** frozen: they can be read, but not added, changed or deleted, until the object is restored. Purging the object removes them.

## Functions

Every function takes the kind of object (`p_kind`: `item`, `stock`, `location` or `class`) and the object's id.

- **`attachment_lock(p_hash)`** and **`attachment_create(p_kind, p_owner, p_hash, p_type, p_size, p_title, p_photo)`** are used by the upload handler, in one transaction: lock the hash, put the file in place, record the attachment. `wtfd gc` takes the same lock before removing a file, so a running upload never loses its file. With `p_photo`, the attachment becomes the object's photo.
- **`attachment_get(p_kind, p_owner, p_id)`** returns `{id, title, type, size, hash, deleted}`, also for a deleted attachment.
- **`attachment_patch(p_kind, p_owner, p_id, p_patch)`** changes the `title`.
- **`attachment_delete(p_kind, p_owner, p_id)`** marks it deleted.
- **`attachment_restore(p_kind, p_owner, p_id, p_options)`** restores it, as an ordinary attachment; its object must be live. There are no options.
- **The photo** is set with the object's own patch: `{"photo": "<attachment id>"}`, or `null` for none (`item_patch`, `stock_patch`, `location_patch`, `class_patch`).
- **Privileges:** attachments of classes belong to the model (model read or data read to read them, model write to change them); all others belong to the data (data read, data write). An attachment of a deleted object can't be added, changed or deleted (55000, 409).

## Where attachments appear

- **`item_get`:** the item's `photo` and attachments, and those of each of its stock rows.
- **`stock_get`, `location_get`, `class_get`:** the object's `photo` and attachments.
- **`item_list`:** each item's `photo`.
- **`class_list`, `location_list`:** each tree node's `photo`. Any change to a class's or location's attachments gives its tree a new version, so a cached tree never shows an old title.
- Attachments are listed with the photo first, then by title; deleted ones aren't listed.

## Stock rows

When `stock_move` splits a row, the new row gets copies of the attachments: new rows with new ids, the same files on disk. The copy of the photo becomes its photo. A row with attachments is never merged into another row, because its attachments would be lost.

## Uploading and downloading

The routes are under the object: `/items/{id}`, `/stock/{id}`, `/locations/{id}` or `/classes/{id}`.

- **Upload:** `POST …/attachments`, with a `multipart/form-data` body:
  - a `file` part (required): its `Content-Type` is kept, and the type is detected when it's missing or `application/octet-stream`;
  - an optional `title` part (default: the file's name);
  - an optional `photo` part (`true`/`false`): make it the object's photo. A file that isn't an image is then refused (422), and nothing is attached.

  The size limit is `--max-attachment-size` (100 MiB by default). `Location` points at the new attachment.
- **Read, rename, delete:** `GET`, `PATCH` (`{title}`) and `DELETE` on `…/attachments/{attachment}`; restore with `POST …/attachments/{attachment}/restore`.
- **Download:** `GET …/attachments/{attachment}/content`.
  - **Name:** the title, plus an extension for the type when the title doesn't already end in one that fits. "Datasheet" as `application/pdf` downloads as `Datasheet.pdf`; "manual.pdf" stays as it is.
  - **Inline or not:** images (except SVG), PDF and plain text are sent `inline`; everything else as a download (`Content-Disposition: attachment`). Downloads also carry `X-Content-Type-Options: nosniff` and `Content-Security-Policy: sandbox`, so an uploaded HTML file can't run as a page on the API's hostname.
  - **Caching:** the `ETag` is the content hash, the content never changes, and `Range` requests work.
