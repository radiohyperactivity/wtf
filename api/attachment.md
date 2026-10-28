# Attachments

The SQL is in [`db/repeatable/80_attachment.sql`](../db/repeatable/80_attachment.sql), and the tables are in [`db/migrations/0004_attachments.sql`](../db/migrations/0004_attachments.sql). The file handling is in [`internal/files`](../internal/files/), and the upload and download handlers are in [`internal/serve/attachments.go`](../internal/serve/attachments.go).

Files (photos, datasheets, manuals, receipts, …) can be attached to items, stock rows, locations and classes. Any file type is accepted.

## The model

- **An attachment** is a row in `attachment`: `id`, `hash` (the hex SHA-256 of the content), `type` (the MIME type) and `title`. The title is given at upload, and defaults to the uploaded file's name.
- **Links:** an attachment is linked to the objects it belongs to through four mapping tables, `item_attachment`, `stock_attachment`, `location_attachment` and `class_attachment`. Each has the pair (object, attachment) as its primary key. An upload links its attachment to one object. Splitting a stock row links the new row to the same attachments, so it shares them.
- **A photo:** items, stock rows, locations and classes each have a `photo` column, naming one of their own attachments. It must be an image (`image/*`) and linked to that object (a trigger checks both). Removing that link clears the photo.
- **Content on disk:** the contents live in `wtfd`'s files directory (`--files-directory`), named by their hash: `<directory>/ab/abcdef…`. A stored file never changes. The same content is stored once on disk, however many attachments have it; the hash isn't unique among attachments.
- **No deleting by marking.** Attachments are removed, not marked deleted. An attachment is deleted as soon as nothing links to it any more (a trigger), and can't be restored; history still records it. Its file goes at the next `wtfd gc`, once no attachment has its hash (see [WTFD.md](../WTFD.md)).
- **Deleted objects keep their attachments,** linked and frozen, and get them back when restored. Purging the object removes its links, and with them the attachments that were only on it.

## Functions

- **`attachment_lock(p_hash)`** and **`attachment_create(p_target_type, p_target, p_hash, p_type, p_title, p_photo)`** are used by the upload handler, in one transaction: lock the hash, put the file in place, record the attachment and its link. `wtfd gc` takes the same lock before removing a file, so a running upload never loses its file. With `p_photo`, the attachment becomes the object's photo.
- **`attachment_get(p_id)`** returns `{id, title, type, hash}`.
- **`attachment_patch(p_id, p_patch)`** changes the `title`.
- **`attachment_unlink(p_target_type, p_target, p_attachment)`** removes an attachment from one object. If that was the last link, the attachment is deleted.
- **`attachment_delete(p_id)`** deletes an attachment for good, from every object it is on.
- **The photo** is set with the object's own patch: `{"photo": "<attachment id>"}`, or `null` for none (`item_patch`, `stock_patch`, `location_patch`, `class_patch`).
- **Privileges:** attachments of classes belong to the model (model write to change them); all others belong to the data (data write). Reading needs model or data read. An attachment on a deleted object can't be changed or removed (55000, 409).

## Where attachments appear

- **`item_get`:** the item's `photo` and attachments, and those of each of its stock rows.
- **`stock_get`, `location_get`, `class_get`:** the object's `photo` and attachments.
- **`item_list`:** each item's `photo`.
- Attachments are listed with the photo first, then by title.

## Stock rows

When `stock_move` splits a row, the new row is linked to the same attachments and gets the same photo. A row with attachments is never merged into another row, because its attachments would be lost.

## Uploading and downloading

- **Upload:** `POST /items/{id}/attachments` (also `/stock/…`, `/locations/…`, `/classes/…`), with a `multipart/form-data` body:
  - a `file` part (required): its `Content-Type` is kept, and the type is detected when it's missing or `application/octet-stream`;
  - an optional `title` part (default: the file's name);
  - an optional `photo` part (`true`/`false`): make it the object's photo. A file that isn't an image is then refused (422), and nothing is attached.

  The size limit is `--max-attachment-size` (100 MiB by default).
- **Remove from an object:** `DELETE /items/{id}/attachments/{attachment}` (also `/stock/…`, `/locations/…`, `/classes/…`).
- **Delete everywhere:** `DELETE /attachments/{id}`.
- **Download:** `GET /attachments/{id}/content`.
  - **Name:** the title, plus an extension for the type when the title doesn't already end in one that fits. "Datasheet" as `application/pdf` downloads as `Datasheet.pdf`; "manual.pdf" stays as it is.
  - **Inline or not:** images (except SVG), PDF and plain text are sent `inline`; everything else as a download (`Content-Disposition: attachment`). Downloads also carry `X-Content-Type-Options: nosniff` and `Content-Security-Policy: sandbox`, so an uploaded HTML file can't run as a page on the API's hostname.
  - **Caching:** the `ETag` is the content hash, the content never changes, and `Range` requests work.
