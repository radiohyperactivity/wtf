package integration

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"strings"
	"testing"

	"github.com/radiohyperactivity/wtf/internal/files"
)

var (
	pngBytes  = []byte("\x89PNG\r\n\x1a\n" + strings.Repeat("pixels", 50))
	pdfBytes  = []byte("%PDF-1.4\n" + strings.Repeat("page ", 50))
	htmlBytes = []byte("<!DOCTYPE html><html><body><script>alert(1)</script></body></html>")
)

// upload posts a multipart upload. An empty contentType leaves the part's
// Content-Type out, so the server has to detect it.
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
	return e.expect(t, status, "POST", path, buf.String(), "Content-Type", mw.FormDataContentType())
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

func TestAttachments(t *testing.T) {
	e := setup(t)
	e.reset(t)

	classID := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools")).body, "id")
	itemID := str(t, e.expect(t, 201, "POST", "/items", obj("class", classID, "name", "Drill")).body, "id")
	garage := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Garage")).body, "id")
	van := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Van")).body, "id")
	stockID := str(t, e.expect(t, 201, "POST", "/stock", obj("item", itemID, "location", garage, "quantity", 2)).body, "id")
	item := "/items/" + itemID + "/attachments"

	// Upload a photo, with a title.
	r := e.upload(t, 201, item, "front.png", "image/png", pngBytes, "title", "Front", "photo", "true")
	photo := r.body
	photoID := str(t, photo, "id")
	if r.header.Get("Location") != "/api/v1"+item+"/"+photoID || str(t, photo, "title") != "Front" ||
		str(t, photo, "type") != "image/png" || num(t, photo, "size") != float64(len(pngBytes)) {
		t.Fatalf("upload: %v %v", r.header, photo)
	}
	pngHash := str(t, photo, "hash")
	if !e.fileExists(t, pngHash) {
		t.Fatal("the file is not in the files directory")
	}
	if a := e.expect(t, 200, "GET", item+"/"+photoID, nil).body; str(t, a, "title") != "Front" {
		t.Errorf("get: %v", a)
	}

	// The photo shows on item_get and item_list.
	got := e.expect(t, 200, "GET", "/items/"+itemID, nil).body
	if str(t, got, "photo", "id") != photoID || len(get(t, got, "attachments").([]any)) != 1 {
		t.Errorf("item_get: photo %v, attachments %v", get(t, got, "photo"), get(t, got, "attachments"))
	}
	list := e.expect(t, 200, "GET", "/items", nil).body
	if str(t, list, "rows", 0, "photo", "id") != photoID {
		t.Errorf("item_list photo: %v", get(t, list, "rows", 0, "photo"))
	}

	// Without a title, the file name is the title; the type is detected; a
	// PDF can't be a photo (and then nothing is attached).
	e.upload(t, 422, item, "manual.pdf", "", pdfBytes, "photo", "true")
	manual := e.upload(t, 201, item, "manual.pdf", "", pdfBytes).body
	if str(t, manual, "type") != "application/pdf" || str(t, manual, "title") != "manual.pdf" {
		t.Errorf("manual: %v", manual)
	}
	if n := len(get(t, e.expect(t, 200, "GET", "/items/"+itemID, nil).body, "attachments").([]any)); n != 2 {
		t.Errorf("item has %d attachments, want 2", n)
	}
	e.expect(t, 422, "PATCH", "/items/"+itemID, obj("photo", str(t, manual, "id")))

	// The same content on another object is an attachment of its own,
	// stored once on disk.
	garagePhoto := e.upload(t, 201, "/locations/"+garage+"/attachments", "garage.png", "image/png", pngBytes).body
	if str(t, garagePhoto, "hash") != pngHash || str(t, garagePhoto, "id") == photoID {
		t.Errorf("the same content: %v", garagePhoto)
	}
	// Attachments are only reached through their own object, and only an
	// object's own attachments can be its photo.
	e.expect(t, 404, "GET", "/locations/"+garage+"/attachments/"+photoID, nil)
	e.expect(t, 404, "GET", "/items/"+itemID+"/attachments/"+str(t, garagePhoto, "id"), nil)
	e.expect(t, 422, "PATCH", "/locations/"+garage, obj("photo", photoID))
	e.expect(t, 200, "PATCH", "/locations/"+garage, obj("photo", str(t, garagePhoto, "id")))
	if str(t, e.expect(t, 200, "GET", "/locations/"+garage, nil).body, "photo", "id") != str(t, garagePhoto, "id") {
		t.Error("location_get photo is not the one set")
	}

	// A new photo replaces the old one; the old one stays as an attachment.
	second := e.upload(t, 201, item, "side.png", "image/png",
		append([]byte(nil), append(pngBytes, 'x')...), "photo", "true").body
	got = e.expect(t, 200, "GET", "/items/"+itemID, nil).body
	if str(t, got, "photo", "id") != str(t, second, "id") || len(get(t, got, "attachments").([]any)) != 3 ||
		str(t, got, "attachments", 0, "id") != str(t, second, "id") {
		t.Errorf("after a new photo: %v", got)
	}
	patched := e.expect(t, 200, "PATCH", item+"/"+photoID, obj("title", " Front view ")).body
	if str(t, patched, "title") != "Front view" {
		t.Errorf("patch: %v", patched)
	}
	e.expect(t, 400, "PATCH", item+"/"+photoID, obj("caption", "x"))
	e.expect(t, 200, "PATCH", "/items/"+itemID, obj("photo", nil))
	if get(t, e.expect(t, 200, "GET", "/items/"+itemID, nil).body, "photo") != nil {
		t.Error("photo: null didn't clear the photo")
	}

	// Download, named after the title with an extension for its type.
	rec := e.raw("GET", item+"/"+photoID+"/content")
	if rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), pngBytes) {
		t.Fatalf("download: %d, %d bytes", rec.Code, rec.Body.Len())
	}
	if rec.Header().Get("Content-Type") != "image/png" ||
		rec.Header().Get("Content-Disposition") != `inline; filename="Front view.png"` ||
		rec.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Errorf("download headers: %v", rec.Header())
	}
	if rec := e.raw("GET", item+"/"+str(t, manual, "id")+"/content"); rec.Header().Get("Content-Disposition") != `inline; filename=manual.pdf` {
		t.Errorf("a title with a fitting extension keeps it: %q", rec.Header().Get("Content-Disposition"))
	}
	if rec := e.raw("GET", item+"/"+photoID+"/content", "If-None-Match", rec.Header().Get("ETag")); rec.Code != 304 {
		t.Errorf("If-None-Match: %d, want 304", rec.Code)
	}
	if rec := e.raw("GET", "/locations/"+garage+"/attachments/"+photoID+"/content"); rec.Code != 404 {
		t.Errorf("another object's attachment: %d, want 404", rec.Code)
	}
	page := e.upload(t, 201, item, "page.html", "text/html", htmlBytes).body
	rec = e.raw("GET", item+"/"+str(t, page, "id")+"/content")
	if !strings.HasPrefix(rec.Header().Get("Content-Disposition"), "attachment") {
		t.Errorf("HTML must be a download, got %q", rec.Header().Get("Content-Disposition"))
	}

	// Stock rows: a split copies the attachments and the photo; a row with
	// attachments isn't merged away.
	receipt := e.upload(t, 201, "/stock/"+stockID+"/attachments", "receipt.png", "image/png",
		append([]byte(nil), append(pngBytes, 'r')...), "photo", "true").body
	split := e.expect(t, 200, "POST", "/stock/"+stockID+"/move", obj("location", van, "quantity", 1)).body
	copied := str(t, split, "attachments", 0, "id")
	if copied == str(t, receipt, "id") || str(t, split, "attachments", 0, "hash") != str(t, receipt, "hash") ||
		str(t, split, "photo", "id") != copied {
		t.Errorf("split-off row: %v", split)
	}
	moved := e.expect(t, 200, "POST", "/stock/"+stockID+"/move", obj("location", van)).body
	if str(t, moved, "id") != stockID {
		t.Error("a row with attachments was merged away")
	}
	// Deleted from one row, the copy stays on the other.
	e.expect(t, 204, "DELETE", "/stock/"+stockID+"/attachments/"+str(t, receipt, "id"), nil)
	if s := e.expect(t, 200, "GET", "/stock/"+stockID, nil).body; get(t, s, "photo") != nil || len(get(t, s, "attachments").([]any)) != 0 {
		t.Errorf("after deleting: %v", s)
	}
	e.expect(t, 200, "GET", "/stock/"+str(t, split, "id")+"/attachments/"+copied, nil)
	e.expect(t, 404, "DELETE", "/stock/"+stockID+"/attachments/"+str(t, receipt, "id"), nil)

	// Limits and format.
	e.upload(t, 413, item, "big.bin", "application/octet-stream", bytes.Repeat([]byte{1}, testMaxAttachment+1))
	e.expect(t, 415, "POST", item, obj("file", "x"))
	e.upload(t, 404, "/items/"+missing+"/attachments", "x.png", "image/png", pngBytes)
	e.upload(t, 400, item, "x.png", "image/png", pngBytes, "caption", "old")

	// A deleted attachment's file goes at gc, once no attachment has its hash.
	htmlHash := str(t, page, "hash")
	e.expect(t, 204, "DELETE", item+"/"+str(t, page, "id"), nil)
	e.expect(t, 404, "GET", item+"/"+str(t, page, "id"), nil)
	gc := func(dryRun bool) files.GCResult {
		result, err := files.GC(context.Background(), files.GCOptions{
			ConnConfig: e.dbaConfig,
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
	// The PNG is on two objects; deleting one keeps the file.
	e.expect(t, 204, "DELETE", "/locations/"+garage+"/attachments/"+str(t, garagePhoto, "id"), nil)
	if get(t, e.expect(t, 200, "GET", "/locations/"+garage, nil).body, "photo") != nil {
		t.Error("a deleted attachment is still the location's photo")
	}
	gc(false)
	if !e.fileExists(t, pngHash) {
		t.Error("gc removed a file another attachment has")
	}
	if rec := e.raw("GET", item+"/"+photoID+"/content"); rec.Code != http.StatusOK {
		t.Errorf("download after gc: %d", rec.Code)
	}

	// A deleted object's attachments are frozen; purging it removes them.
	old := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Old")).body, "id")
	guide := e.upload(t, 201, "/classes/"+old+"/attachments", "guide.pdf", "application/pdf", pdfBytes).body
	guidePath := "/classes/" + old + "/attachments/" + str(t, guide, "id")
	e.expect(t, 204, "DELETE", "/classes/"+old, nil)
	e.expect(t, 200, "GET", guidePath, nil)
	e.expect(t, 409, "PATCH", guidePath, obj("title", "x"))
	e.expect(t, 409, "DELETE", guidePath, nil)
	e.upload(t, 409, "/classes/"+old+"/attachments", "more.pdf", "application/pdf", pdfBytes)
	purgeDeleted(t, e)
	e.expect(t, 404, "GET", guidePath, nil)
}
