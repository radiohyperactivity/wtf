# Files

The SQL is in [`db/repeatable/13_attachment.sql`](../db/repeatable/13_attachment.sql). The file handling is in [`internal/files`](../internal/files/), and the upload and download handlers are in [`internal/serve/attachments.go`](../internal/serve/attachments.go).

An item or a stock row has files in two ways:

- **a photo**, in its `photo` column, which must be an image;
- **the file of an attachment attribute** of its class ([attribute.md](attribute.md)), as that value: a datasheet, a manual, a receipt. Only the attachments a class defines can be uploaded, one file each, of the media types the attribute lists, if it lists any.

Locations and classes have no files.

## The model

- **A file is its hash:** the photo and an attachment's value are the hex SHA-256 of the file's content, and nothing more. Its size is read from the file. Its media type is found from its first bytes, at upload and when serving, not taken from the client: sniffing tells images and PDF well, while Word and Excel files come out as ZIP archives, and CSV as plain text.
- **Content on disk:** the contents live in `wtfd`'s files directory (`--files-directory`), named by their hash: `<directory>/ab/abcdef…`. A stored file never changes, and the same content is stored once, however many items and stock rows have it.
- **Removing** a file is a patch: `{"photo": null}`, or `{"values": {"Manual": null}}`. `wtfd gc` removes a file once nothing has its hash any more (see [WTFD.md](../WTFD.md)), and deleting an item or stock row leaves its files to `gc` too.

## Functions

- **`attachment.lock(p_hash)`** and **`attachment.set(p_kind, p_owner, p_attribute, p_hash, p_media_type)`** are used by the upload handler, in one transaction: lock the hash, put the file in place, set the photo (`p_attribute` null) or the attribute's value. `wtfd gc` takes the same lock (`attachment.file_lock_key`) before removing a file, so a running upload never loses its file. The handler checks the session (`account.me`) before it stores anything. `p_kind` is `item` or `stock`; a file already there is replaced. Users may upload.
- **`attachment.get(p_kind, p_owner, p_attribute)`** returns `{hash, name}` of a photo (`p_attribute` null) or an attachment value, for the download handler; `name` is the attribute's, or "Photo".

## Uploading and downloading

The routes are under the item or stock row: `/items/{id}` or `/stock/{id}`.

- **Upload:** `PUT …/photo`, or `PUT …/files/{attribute}`, with a `multipart/form-data` body of one `file` part. It answers the item or stock row. The size limit is `--max-attachment-size` (100 MiB by default). A photo that isn't an image is refused (400); a file of a type the attribute doesn't take is refused (422).
- **Download:** `GET …/photo`, or `GET …/files/{attribute}`.
  - **Name:** the attribute's name ("Photo" for the photo), with an extension for the type: a manual as `application/pdf` downloads as `Manual.pdf`.
  - **Inline or not:** images (except SVG), PDF and plain text are sent `inline`; everything else as a download (`Content-Disposition: attachment`). Downloads also carry `X-Content-Type-Options: nosniff` and `Content-Security-Policy: sandbox`, so an uploaded HTML file can't run as a page on the API's hostname.
  - **Caching:** the `ETag` is the content hash, the content never changes, and `Range` requests work.

## Stock rows

When `stock.move` splits a row, the new row has the same photo and attachment values: the same files on disk. When `stock.merge` finds that two rows' photos or files differ, the client says which to keep, as for any other difference ([location.md](location.md)).
