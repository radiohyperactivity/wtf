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
)

const (
	// Uploads and downloads may take longer than the server-wide timeouts.
	transferTimeout = 15 * time.Minute

	// Room for the multipart framing and the small fields of an upload.
	multipartOverhead = 1 << 20
)

// upload attaches a multipart/form-data upload to an object of targetType.
// Parts: "file" (required; its file name and Content-Type are kept),
// "caption" and "primary_photo" (true/false).
func (s *server) upload(targetType string) handlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		target := r.PathValue("id")
		if !uuidPattern.MatchString(target) {
			return invalidInput("%q in the path is not a UUID", target)
		}
		_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(transferTimeout))

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
			staged       *files.Staged
			placed       bool
			fileName     string
			contentType  string
			caption      *string
			primaryPhoto bool
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
			switch part.FormName() {
			case "file":
				if staged != nil {
					return invalidInput("only one \"file\" part is allowed")
				}
				fileName = part.FileName()
				if fileName == "" {
					return invalidInput("the \"file\" part needs a file name")
				}
				contentType = part.Header.Get("Content-Type")
				staged, err = s.files.Stage(part, s.maxAttachment)
				if errors.Is(err, files.ErrTooLarge) {
					return &problem{
						Type:   "/problems/body-too-large",
						Title:  "File too large",
						Status: http.StatusRequestEntityTooLarge,
						Detail: "An attachment may be at most " + strconv.FormatInt(s.maxAttachment, 10) + " bytes.",
					}
				}
				if err != nil {
					return err
				}
			case "caption":
				text, err := readField(part)
				if err != nil {
					return err
				}
				caption = &text
			case "primary_photo":
				text, err := readField(part)
				if err != nil {
					return err
				}
				if primaryPhoto, err = strconv.ParseBool(text); err != nil {
					return invalidInput("primary_photo must be true or false")
				}
			default:
				return invalidInput("unknown part %q", part.FormName())
			}
		}
		if staged == nil {
			return invalidInput("a \"file\" part is required")
		}

		if t, _, err := mime.ParseMediaType(contentType); err == nil && t != "application/octet-stream" {
			contentType = t
		} else {
			contentType, _, _ = mime.ParseMediaType(http.DetectContentType(staged.Head))
		}

		var captionArg any
		if caption != nil {
			captionArg = *caption
		}
		var result string
		sess, _ := r.Context().Value(sessionKey{}).(session)
		err = pgx.BeginFunc(r.Context(), s.pool, func(tx pgx.Tx) error {
			if err := useSession(r.Context(), tx, sess); err != nil {
				return err
			}
			if _, err := tx.Exec(r.Context(), "SELECT attachment_lock($1)", staged.Hash); err != nil {
				return err
			}
			if err := staged.Place(); err != nil {
				return err
			}
			placed = true
			sql, values := callSQL("attachment_create", []arg{
				{name: "p_target_type", typ: "text", value: targetType},
				{name: "p_target", typ: "uuid", value: target},
				{name: "p_sha256", typ: "text", value: staged.Hash},
				{name: "p_size", typ: "bigint", value: staged.Size},
				{name: "p_file_name", typ: "text", value: fileName},
				{name: "p_content_type", typ: "text", value: contentType},
				{name: "p_caption", typ: "text", value: captionArg},
				{name: "p_primary_photo", typ: "boolean", value: primaryPhoto},
			})
			return tx.QueryRow(r.Context(), sql+"::text", values...).Scan(&result)
		})
		if err != nil {
			return err // a placed but unrecorded file is removed by "wtfd gc"
		}

		var created struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal([]byte(result), &created); err != nil {
			return err
		}
		w.Header().Set("Location", apiPrefix+"/attachments/"+created.ID)
		writeJSON(w, http.StatusCreated, []byte(result))
		return nil
	}
}

// readField reads a small multipart text field.
func readField(part io.Reader) (string, error) {
	data, err := io.ReadAll(io.LimitReader(part, 4097))
	if err != nil {
		return "", err
	}
	if len(data) > 4096 {
		return "", invalidInput("text fields may be at most 4096 bytes")
	}
	return string(data), nil
}

// download sends an attachment's content. Only content types that can't run
// scripts in a browser are shown inline; everything else is a download. The
// content of an attachment never changes, so it can be cached for good.
func (s *server) download(w http.ResponseWriter, r *http.Request) error {
	args, err := collect(r, []param{path("p_id", "id")})
	if err != nil {
		return err
	}
	result, err := s.callJSON(r.Context(), "attachment_get", args)
	if err != nil {
		return err
	}
	var a struct {
		FileName    string `json:"file_name"`
		ContentType string `json:"content_type"`
		SHA256      string `json:"sha256"`
	}
	if err := json.Unmarshal(result, &a); err != nil {
		return err
	}

	f, err := s.files.OpenFile(a.SHA256)
	if errors.Is(err, fs.ErrNotExist) {
		s.log.Error("attachment file missing", "attachment", r.PathValue("id"), "sha256", a.SHA256)
		return &problem{
			Type:   "/problems/internal",
			Title:  "Attachment file missing",
			Status: http.StatusInternalServerError,
			Detail: "The file of this attachment is missing from the files directory; restore it from a backup.",
		}
	}
	if err != nil {
		return err
	}
	defer f.Close()

	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(transferTimeout))
	disposition := "attachment"
	if inlineSafe(a.ContentType) {
		disposition = "inline"
	}
	h := w.Header()
	h.Set("Content-Type", a.ContentType)
	h.Set("Content-Disposition", mime.FormatMediaType(disposition, map[string]string{"filename": a.FileName}))
	h.Set("ETag", `"`+a.SHA256+`"`)
	h.Set("Cache-Control", "private, max-age=31536000, immutable")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "sandbox")
	http.ServeContent(w, r, "", time.Time{}, f)
	return nil
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
