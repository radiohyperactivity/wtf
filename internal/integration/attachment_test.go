package integration

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/jpeg"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"strings"
	"testing"
	"time"

	"github.com/radiohyperactivity/wtf/internal/files"
)

var (
	pngBytes  = []byte("\x89PNG\r\n\x1a\n" + strings.Repeat("pixels", 50))
	pdfBytes  = []byte("%PDF-1.4\n" + strings.Repeat("page ", 50))
	htmlBytes = []byte("<!DOCTYPE html><html><body><script>alert(1)</script></body></html>")
)

// upload puts a multipart upload. The server finds the media type from the
// content, whatever contentType the part says (none when empty).
func (e *environment) upload(t *testing.T, status int, path, fileName, contentType string, content []byte, fields ...string) response {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for i := 0; i+1 < len(fields); i += 2 {
		if err := mw.WriteField(fields[i], fields[i+1]); err != nil {
			t.Fatal(err)
		}
	}
	h := textproto.MIMEHeader{}
	h.Set("Content-Disposition", fmt.Sprintf(`form-data; name="file"; filename=%q`, fileName))
	if contentType != "" {
		h.Set("Content-Type", contentType)
	}
	part, err := mw.CreatePart(h)
	if err != nil {
		t.Fatal(err)
	}
	part.Write(content)
	mw.Close()
	return e.expect(t, status, "PUT", path, buf.String(), "Content-Type", mw.FormDataContentType())
}

// raw sends a request and returns the recorder, without decoding JSON.
func (e *environment) raw(method, path string, headers ...string) *httptest.ResponseRecorder {
	req := e.newRequest(method, path, nil, headers...)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	return rec
}

func (e *environment) fileExists(t *testing.T, hash string) bool {
	t.Helper()
	f, err := e.files.OpenFile(hash)
	if err != nil {
		return false
	}
	f.Close()
	return true
}

func TestFiles(t *testing.T) {
	e := setup(t)
	e.reset(t)

	tools := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools")).body, "id")
	attribute := func(name string, def map[string]any) {
		e.expect(t, 200, "POST", "/classes/"+tools+"/attributes", obj("name", name, "definition", def))
	}
	attribute("Manual", obj("scope", "item", "type", "attachment", "media", []string{"application/pdf"}))
	attribute("Page", obj("scope", "item", "type", "attachment"))
	attribute("Note", obj("scope", "item", "type", "text"))
	attribute("Receipt", obj("scope", "stock", "type", "attachment", "media", []string{"image/*"}))
	itemID := str(t, e.expect(t, 201, "POST", "/items", obj("class", tools, "name", "Drill")).body, "id")
	garage := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Garage")).body, "id")
	van := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Van")).body, "id")
	stockID := str(t, e.expect(t, 201, "POST", "/stock", obj("item", itemID, "location", garage, "amount", 2)).body, "id")
	item := "/items/" + itemID

	// A photo, which must be an image, whatever the upload says it is.
	e.upload(t, 400, item+"/photo", "manual.pdf", "image/png", pdfBytes)
	got := e.upload(t, 200, item+"/photo", "front.png", "", pngBytes).body
	pngHash := str(t, got, "photo")
	if !e.fileExists(t, pngHash) {
		t.Fatal("the file is not in the files directory")
	}
	if list := e.expect(t, 200, "GET", "/items", nil).body; str(t, list, "rows", 0, "photo") != pngHash {
		t.Errorf("item list photo: %v", get(t, list, "rows", 0, "photo"))
	}

	// An attachment attribute takes the media types it lists.
	e.upload(t, 422, item+"/files/Manual", "front.png", "application/pdf", pngBytes)
	got = e.upload(t, 200, item+"/files/Manual", "manual.pdf", "", pdfBytes).body
	pdfHash := str(t, get(t, got, "values"), "Manual")
	e.upload(t, 404, item+"/files/Note", "note.png", "", pngBytes)
	e.upload(t, 404, item+"/files/Nothing", "x.png", "", pngBytes)
	e.expect(t, 400, "PATCH", item, obj("values", obj("Manual", pdfHash)))

	// Downloads, named after the attribute, with an extension for the type.
	rec := e.raw("GET", item+"/photo")
	if rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), pngBytes) {
		t.Fatalf("download: %d, %d bytes", rec.Code, rec.Body.Len())
	}
	if rec.Header().Get("Content-Type") != "image/png" ||
		rec.Header().Get("Content-Disposition") != `inline; filename=Photo.png` ||
		rec.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Errorf("download headers: %v", rec.Header())
	}
	if rec := e.raw("GET", item+"/photo", "If-None-Match", rec.Header().Get("ETag")); rec.Code != 304 {
		t.Errorf("If-None-Match: %d, want 304", rec.Code)
	}
	// Thumbnails: what isn't an image wtfd can scale comes as it is, and a
	// size must be a number.
	if rec := e.raw("GET", item+"/photo?size=96"); rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), pngBytes) {
		t.Errorf("a thumbnail of what can't have one: %d, %d bytes", rec.Code, rec.Body.Len())
	}
	if rec := e.raw("GET", item+"/photo?size=big"); rec.Code != 400 {
		t.Errorf("size=big: %d, want 400", rec.Code)
	}
	thumbnails(t, e, "/locations/"+van+"/photo")

	if rec := e.raw("GET", item+"/files/Manual"); rec.Header().Get("Content-Type") != "application/pdf" ||
		rec.Header().Get("Content-Disposition") != `inline; filename=Manual.pdf` {
		t.Errorf("the manual: %v", rec.Header())
	}
	e.upload(t, 200, item+"/files/Page", "page.html", "text/plain", htmlBytes)
	if rec := e.raw("GET", item+"/files/Page"); !strings.HasPrefix(rec.Header().Get("Content-Disposition"), "attachment") {
		t.Errorf("HTML must be a download, got %q", rec.Header().Get("Content-Disposition"))
	}
	if rec := e.raw("GET", item+"/files/Note"); rec.Code != 404 {
		t.Errorf("a text attribute's file: %d, want 404", rec.Code)
	}

	// Stock rows: a photo only where the location takes them; a split
	// takes the photo along, also to a location that doesn't, and the same
	// content is stored once.
	stock := "/stock/" + stockID
	refused := e.upload(t, 422, stock+"/photo", "front.png", "", pngBytes).body
	if !strings.Contains(str(t, refused, "detail"), `Stock at "Garage" has no photos of its own`) {
		t.Errorf("a stock photo where the location takes none: %v", refused)
	}
	e.expect(t, 200, "PATCH", "/locations/"+garage, obj("stock_photos", true))
	if got := e.upload(t, 200, stock+"/photo", "front.png", "", pngBytes).body; str(t, got, "photo") != pngHash {
		t.Errorf("the same content: %v", got)
	}
	e.upload(t, 200, stock+"/files/Receipt", "receipt.png", "", append([]byte(nil), append(pngBytes, 'r')...))
	rows := e.expect(t, 200, "GET", "/stock?item="+itemID, nil).body
	if str(t, rows, "rows", 0, "photo") != pngHash || str(t, rows, "rows", 0, "item", "photo") != pngHash {
		t.Errorf("stock list photos: %v", get(t, rows, "rows", 0))
	}
	split := e.expect(t, 200, "POST", stock+"/move", obj("location", van, "amount", 1)).body
	if str(t, split, "photo") != pngHash || get(t, split, "values", "Receipt") == nil {
		t.Errorf("split-off row: %v", split)
	}

	// Locations: a photo, shown in the tree, for admins, and no other
	// files.
	location := "/locations/" + garage
	garagePNG := append(append([]byte(nil), pngBytes...), 'g')
	garageHash := str(t, e.upload(t, 200, location+"/photo", "garage.png", "", garagePNG).body, "photo")
	if tree := e.expect(t, 200, "GET", "/locations", nil).body; str(t, tree, "tree", 0, "photo") != garageHash {
		t.Errorf("location tree photo: %v", get(t, tree, "tree", 0))
	}
	if rec := e.raw("GET", location+"/photo"); rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), garagePNG) {
		t.Errorf("location photo: %d", rec.Code)
	}
	e.upload(t, 400, location+"/photo", "manual.pdf", "", pdfBytes)
	e.upload(t, 404, "/locations/"+missing+"/photo", "x.png", "", pngBytes)
	e.expect(t, 404, "PUT", location+"/files/Receipt", nil)
	e.expect(t, 400, "PATCH", location, obj("photo", "abc"))
	email := fmt.Sprintf("files-%d@test.local", time.Now().UnixNano())
	e.expect(t, 201, "POST", "/accounts", obj("email", email, "password", "secret-password", "role", "user"))
	user := session(t, e.expect(t, 200, "POST", "/login",
		obj("email", email, "password", "secret-password", "client", "test", "max_idle", nil), "Cookie", ""))
	e.expect(t, 403, "PATCH", location, obj("photo", nil), as(user)...)
	body, contentType := photoUpload(t, garagePNG)
	e.expect(t, 403, "PUT", location+"/photo", body, append([]string{"Content-Type", contentType}, as(user)...)...)
	if got := e.expect(t, 200, "PATCH", location, obj("photo", nil)).body; get(t, got, "photo") != nil {
		t.Errorf("location photo removed: %v", got)
	}
	e.upload(t, 200, location+"/photo", "garage.png", "", garagePNG)

	// Limits and format.
	e.upload(t, 413, item+"/files/Page", "big.bin", "application/octet-stream", bytes.Repeat([]byte{1}, testMaxAttachment+1))
	e.expect(t, 415, "PUT", item+"/photo", obj("file", "x"))
	e.upload(t, 404, "/items/"+missing+"/photo", "x.png", "image/png", pngBytes)
	e.upload(t, 400, item+"/photo", "x.png", "image/png", pngBytes, "caption", "old")

	// gc removes a file nothing has any more, and keeps one that something
	// still has.
	htmlHash := str(t, get(t, e.expect(t, 200, "GET", item, nil).body, "values"), "Page")
	e.expect(t, 200, "PATCH", item, obj("values", obj("Page", nil), "photo", nil))
	gc := func(dryRun bool) files.GCResult {
		result, err := files.GC(context.Background(), files.GCOptions{
			ConnConfig: e.apiConfig,
			Store:      e.files,
			DryRun:     dryRun,
			Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	if r := gc(true); r.Files == 0 || !e.fileExists(t, htmlHash) {
		t.Errorf("dry run: %+v, file exists: %v", r, e.fileExists(t, htmlHash))
	}
	gc(false)
	if e.fileExists(t, htmlHash) {
		t.Error("gc kept an unreferenced file")
	}
	if !e.fileExists(t, pngHash) || !e.fileExists(t, pdfHash) || !e.fileExists(t, garageHash) {
		t.Error("gc removed a file a stock row, a location or a value has")
	}
	if rec := e.raw("GET", stock+"/photo"); rec.Code != http.StatusOK {
		t.Errorf("download after gc: %d", rec.Code)
	}
}

// thumbnails puts a photo at path, 600 by 400, and checks its thumbnails:
// ?size=N fits it in the box of the thumbnail size N is rounded up to, as
// JPEG, with an ETag of its own; a size larger than thumbnails are gets
// the photo itself.
func thumbnails(t *testing.T, e *environment, path string) {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 600, 400))
	for i := range img.Pix {
		img.Pix[i] = 200
	}
	var photo bytes.Buffer
	if err := jpeg.Encode(&photo, img, nil); err != nil {
		t.Fatal(err)
	}
	e.upload(t, 200, path, "photo.jpg", "", photo.Bytes())
	whole := e.raw("GET", path)

	rec := e.raw("GET", path+"?size=100")
	if rec.Code != 200 || rec.Header().Get("Content-Type") != "image/jpeg" {
		t.Fatalf("thumbnail: %d, %v", rec.Code, rec.Header())
	}
	small, err := jpeg.DecodeConfig(rec.Body)
	if err != nil || small.Width != 128 || small.Height != 85 {
		t.Errorf("thumbnail: %d×%d, %v; want 128×85", small.Width, small.Height, err)
	}
	etag := rec.Header().Get("ETag")
	if etag == whole.Header().Get("ETag") || !strings.HasSuffix(etag, `-128"`) {
		t.Errorf("the thumbnail's ETag %s, the photo's %s", etag, whole.Header().Get("ETag"))
	}
	if again := e.raw("GET", path+"?size=128", "If-None-Match", etag); again.Code != 304 {
		t.Errorf("the same thumbnail again: %d, want 304", again.Code)
	}
	if rec := e.raw("GET", path+"?size=2000"); !bytes.Equal(rec.Body.Bytes(), photo.Bytes()) {
		t.Errorf("larger than thumbnails: %d bytes, want the photo's %d", rec.Body.Len(), photo.Len())
	}
}
