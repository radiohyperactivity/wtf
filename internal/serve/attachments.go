package serve

import (
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/radiohyperactivity/wtf/internal/files"
	"github.com/radiohyperactivity/wtf/internal/mediatype"
)

const (
	// Uploads and downloads may take longer than the server-wide timeouts.
	transferTimeout = 15 * time.Minute

	// Room for the multipart framing and the small fields of an upload.
	multipartOverhead = 1 << 20
)

// upload puts a multipart/form-data upload on an item or a stock row
// (kind): as its photo, or, with attribute, as the file of attachment
// attribute {attribute} of its class. The one part is "file". Its media
// type is found from its first bytes, not taken from the client, so that
// a photo is an image and an attribute's media types mean what they say.
// Answers the item or stock row as its get does.
func (s *server) upload(kind string, attribute bool) handlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		target := r.PathValue("id")
		if !uuidPattern.MatchString(target) {
			return invalidInput("%q in the path is not a UUID", target)
		}
		name := arg{name: "p_attribute", typ: "text"}
		if attribute {
			name.value = r.PathValue("attribute")
		}
		_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(transferTimeout))
		// The session is checked before anything is written to the files
		// directory: nothing is kept for a request without a valid session.
		if _, err := s.callJSON(r.Context(), "account.me", nil); err != nil {
			return err
		}
		who := callerOf(r.Context())

		mediaType, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if mediaType != "multipart/form-data" {
			return &problem{
				Type:   "/problems/unsupported-media-type",
				Title:  "Unsupported media type",
				Status: http.StatusUnsupportedMediaType,
				Detail: "Uploads must be multipart/form-data with a \"file\" part.",
			}
		}
		parts, err := r.MultipartReader()
		if err != nil {
			return invalidInput("malformed multipart body: %v", err)
		}

		var (
			staged *files.Staged
			placed bool
		)
		defer func() {
			if staged != nil && !placed {
				staged.Discard()
			}
		}()

		for {
			part, err := parts.NextPart()
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				return invalidInput("malformed multipart body: %v", err)
			}
			if part.FormName() != "file" {
				return invalidInput("unknown part %q; an upload has one part, \"file\"", part.FormName())
			}
			if staged != nil {
				return invalidInput("only one \"file\" part is allowed")
			}
			staged, err = s.files.Stage(part, s.maxAttachment)
			if errors.Is(err, files.ErrTooLarge) {
				return &problem{
					Type:   "/problems/body-too-large",
					Title:  "File too large",
					Status: http.StatusRequestEntityTooLarge,
					Detail: "A file may be at most " + strconv.FormatInt(s.maxAttachment, 10) + " bytes.",
				}
			}
			if err != nil {
				return err
			}
		}
		if staged == nil {
			return invalidInput("a \"file\" part is required")
		}
		contentType := sniff(staged.Head)

		// One transaction of its own: the file's lock (which "wtfd gc" takes
		// too), the file put in place, and the item or stock row changed.
		var result string
		err = pgx.BeginFunc(r.Context(), s.pool, func(tx pgx.Tx) error {
			sql, values := callSQL("attachment.lock", who, []arg{{name: "p_hash", typ: "text", value: staged.Hash}})
			if _, err := tx.Exec(r.Context(), sql, values...); err != nil {
				return err
			}
			if err := staged.Place(); err != nil {
				return err
			}
			placed = true
			sql, values = callSQL("attachment.set", who, []arg{
				{name: "p_kind", typ: "text", value: kind},
				{name: "p_owner", typ: "uuid", value: target},
				name,
				{name: "p_hash", typ: "text", value: staged.Hash},
				{name: "p_media_type", typ: "text", value: contentType},
			})
			return tx.QueryRow(r.Context(), sql+"::text", values...).Scan(&result)
		})
		if err != nil {
			return err // a placed but unused file is removed by "wtfd gc"
		}
		writeJSON(w, http.StatusOK, []byte(result))
		return nil
	}
}

// sniff is the media type of a file, from its first bytes (at most 512):
// http.DetectContentType's, without its parameters.
func sniff(head []byte) string {
	t, _, err := mime.ParseMediaType(http.DetectContentType(head))
	if err != nil {
		return "application/octet-stream"
	}
	return t
}

// download sends a file of an item or a stock row (kind): its photo, or,
// with attribute, the file of attachment attribute {attribute}, named after
// the attribute (see mediatype.DownloadName). Its media type is found from
// its first bytes, as at upload. Only content types that can't run scripts
// in a browser are shown inline; everything else is a download. A file's
// content never changes, so it can be cached for good.
func (s *server) download(kind string, attribute bool) handlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		name := arg{name: "p_attribute", typ: "text"}
		if attribute {
			name.value = r.PathValue("attribute")
		}
		args, err := collect(r, []param{constant("p_kind", "text", kind), path("p_owner", "id")})
		if err != nil {
			return err
		}
		result, err := s.callJSON(r.Context(), "attachment.get", append(args, name))
		if err != nil {
			return err
		}
		var a struct {
			Name string `json:"name"`
			Hash string `json:"hash"`
		}
		if err := json.Unmarshal(result, &a); err != nil {
			return err
		}

		f, err := s.files.OpenFile(a.Hash)
		if errors.Is(err, fs.ErrNotExist) {
			s.log.Error("file missing", "kind", kind, "id", r.PathValue("id"), "sha256", a.Hash)
			return &problem{
				Type:   "/problems/internal",
				Title:  "File missing",
				Status: http.StatusInternalServerError,
				Detail: "This file is missing from the files directory; restore it from a backup.",
			}
		}
		if err != nil {
			return err
		}
		defer f.Close()
		head := make([]byte, 512)
		n, err := io.ReadFull(f, head)
		if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
			return err
		}
		contentType := sniff(head[:n])

		_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(transferTimeout))
		disposition := "attachment"
		if inlineSafe(contentType) {
			disposition = "inline"
		}
		h := w.Header()
		h.Set("Content-Type", contentType)
		h.Set("Content-Disposition", mime.FormatMediaType(disposition,
			map[string]string{"filename": mediatype.DownloadName(a.Name, contentType)}))
		h.Set("ETag", `"`+a.Hash+`"`)
		h.Set("Cache-Control", "private, max-age=31536000, immutable")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Content-Security-Policy", "sandbox")
		http.ServeContent(w, r, "", time.Time{}, f)
		return nil
	}
}

// inlineSafe reports whether a content type may be shown inline: images
// (except SVG, which can contain scripts), PDF and plain text.
func inlineSafe(contentType string) bool {
	switch {
	case contentType == "image/svg+xml":
		return false
	case strings.HasPrefix(contentType, "image/"):
		return true
	case contentType == "application/pdf", contentType == "text/plain":
		return true
	}
	return false
}
