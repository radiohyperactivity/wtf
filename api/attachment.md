# Attachments

The SQL is in [`db/repeatable/80_attachment.sql`](../db/repeatable/80_attachment.sql). The file handling is in [`internal/files`](../internal/files/), and the upload and download handlers are in [`internal/serve/attachments.go`](../internal/serve/attachments.go).

Files (photos, datasheets, manuals, receipts, …) can be attached to items, stock rows, locations and classes. Any file type is accepted.

## Storage

- **Content on disk:** the file contents live in `wtfd`'s files directory (`--files-directory`), named by their SHA-256 hash: `<directory>/ab/abcdef…`. A stored file never changes, and the same content is stored only once, however often it is attached.
- **Metadata in the database:** a `file` row per stored content (hash, size), and an `attachment` row per attachment (file name, content type, caption, primary photo flag, and the one object it belongs to).
- **Deleting** an attachment, or the object it belongs to, marks it deleted and keeps the file (see [deleting.md](deleting.md)). Once it is purged, `wtfd gc` removes files that nothing references any more (see [WTFD.md](../WTFD.md)).

## Functions

- **`attachment_lock(p_sha256)`** and **`attachment_create(p_target_type, p_target, p_sha256, p_size, p_file_name, p_content_type, p_caption, p_primary_photo)`** are used by the upload handler, in one transaction: lock the hash, put the file in place, record it. `wtfd gc` takes the same lock before removing a file, so a running upload never loses its file.
- **`attachment_get(p_id)`**, **`attachment_patch(p_id, p_patch)`** (`file_name`, `caption`, `primary_photo`) **`attachment_delete(p_id)`** and **`attachment_restore(p_id, p_options)`**.

## Primary photo

One attachment per object can be its primary photo. Only images (`image/*`) qualify. Marking a new one replaces the previous one. Items show their primary photo as `photo` in `item_list` rows and in `item_get`.

## Where attachments appear

- **`item_get`:** the item's own attachments, and the attachments of each of its stock rows.
- **`stock_get`, `location_get`, `class_get`:** the object's attachments.

## Stock rows

When `stock_move` splits a row, the new row gets copies of the attachments (the same files, not copied on disk). A row with attachments is never merged into another row, because its attachments would be lost.

## Uploading and downloading

- **Upload:** `POST /items/{id}/attachments` (also `/stock/…`, `/locations/…`, `/classes/…`), with a `multipart/form-data` body:
  - a `file` part (required): its file name and `Content-Type` are kept, and the type is detected when it's missing or `application/octet-stream`;
  - optional `caption` and `primary_photo` (`true`/`false`) parts.

  The size limit is `--max-attachment-size` (100 MiB by default).
- **Download:** `GET /attachments/{id}/content`.
  - Images (except SVG), PDF and plain text are sent `inline`; everything else as a download (`Content-Disposition: attachment`). Downloads also carry `X-Content-Type-Options: nosniff` and `Content-Security-Policy: sandbox`, so an uploaded HTML file can't run as a page on the API's hostname.
  - The `ETag` is the content hash, the content never changes, and `Range` requests work.
