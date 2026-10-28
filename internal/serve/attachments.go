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

// upload attaches a multipart/form-data upload to an object of kind, whose
// routes are under /kindPath.
// Parts: "file" (required; its Content-Type is kept, and its file name is
// the title unless a "title" part gives one) and "photo" (true/false: make
// it the object's photo).
func (s *server) upload(kind, kindPath string) handlerFunc {
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
			staged      *files.Staged
			placed      bool
			fileName    string
			contentType string
			title       string
			photo       bool
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
				store, err := s.files.Tenant(tenantOf(r.Context()))
				if err != nil {
					return err
				}
				staged, err = store.Stage(part, s.maxAttachment)
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
			case "title":
				if title, err = readField(part); err != nil {
					return err
				}
			case "photo":
				text, err := readField(part)
				if err != nil {
					return err
				}
				if photo, err = strconv.ParseBool(text); err != nil {
					return invalidInput("photo must be true or false")
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

		if strings.TrimSpace(title) == "" {
			title = fileName
		}
		var result string
		sess, _ := r.Context().Value(sessionKey{}).(session)
		err = pgx.BeginFunc(r.Context(), s.pool, func(tx pgx.Tx) error {
			if err := useSession(r.Context(), tx, sess, tenantOf(r.Context())); err != nil {
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
				{name: "p_kind", typ: "text", value: kind},
				{name: "p_owner", typ: "uuid", value: target},
				{name: "p_hash", typ: "text", value: staged.Hash},
				{name: "p_type", typ: "text", value: contentType},
				{name: "p_size", typ: "bigint", value: staged.Size},
				{name: "p_title", typ: "text", value: title},
				{name: "p_photo", typ: "boolean", value: photo},
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
		w.Header().Set("Location", apiPrefix+"/"+kindPath+"/"+target+"/attachments/"+created.ID)
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

// download sends an attachment's content, named after its title (see
// mediatype.DownloadName). Only content types that can't run scripts in a browser are
// shown inline; everything else is a download. The content of an attachment
// never changes, so it can be cached for good.
func (s *server) download(kind string) handlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		return s.sendAttachment(w, r, kind)
	}
}

func (s *server) sendAttachment(w http.ResponseWriter, r *http.Request, kind string) error {
	args, err := collect(r, []param{constant("p_kind", "text", kind), path("p_owner", "id"), path("p_id", "attachment")})
	if err != nil {
		return err
	}
	result, err := s.callJSON(r.Context(), "attachment_get", args)
	if err != nil {
		return err
	}
	var a struct {
		Title string `json:"title"`
		Type  string `json:"type"`
		Hash  string `json:"hash"`
	}
	if err := json.Unmarshal(result, &a); err != nil {
		return err
	}

	store, err := s.files.Tenant(tenantOf(r.Context()))
	if err != nil {
		return err
	}
	f, err := store.OpenFile(a.Hash)
	if errors.Is(err, fs.ErrNotExist) {
		s.log.Error("attachment file missing", "attachment", r.PathValue("attachment"), "sha256", a.Hash)
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
	if inlineSafe(a.Type) {
		disposition = "inline"
	}
	h := w.Header()
	h.Set("Content-Type", a.Type)
	h.Set("Content-Disposition", mime.FormatMediaType(disposition, map[string]string{"filename": mediatype.DownloadName(a.Title, a.Type)}))
	h.Set("ETag", `"`+a.Hash+`"`)
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
