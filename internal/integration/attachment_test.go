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

	// Upload a primary photo.
	r := e.upload(t, 201, "/items/"+itemID+"/attachments", "front.png", "image/png", pngBytes,
		"caption", "Front", "primary_photo", "true")
	photo := r.body
	photoID := str(t, photo, "id")
	if r.header.Get("Location") != "/api/v1/attachments/"+photoID || get(t, photo, "primary_photo") != true ||
		str(t, photo, "caption") != "Front" || num(t, photo, "size") != float64(len(pngBytes)) {
		t.Fatalf("upload: %v %v", r.header, photo)
	}
	pngHash := str(t, photo, "sha256")
	if !e.fileExists(t, pngHash) {
		t.Fatal("the file is not in the files directory")
	}

	// The primary photo shows on item_get and item_list.
	item := e.expect(t, 200, "GET", "/items/"+itemID, nil).body
	if str(t, item, "photo", "id") != photoID || len(get(t, item, "attachments").([]any)) != 1 {
		t.Errorf("item_get: photo %v, attachments %v", get(t, item, "photo"), get(t, item, "attachments"))
	}
	list := e.expect(t, 200, "GET", "/items", nil).body
	if str(t, list, "rows", 0, "photo", "id") != photoID {
		t.Errorf("item_list photo: %v", get(t, list, "rows", 0, "photo"))
	}

	// Content type detection, and a PDF can't be the primary photo.
	e.upload(t, 422, "/items/"+itemID+"/attachments", "manual.pdf", "", pdfBytes, "primary_photo", "true")
	manual := e.upload(t, 201, "/items/"+itemID+"/attachments", "manual.pdf", "", pdfBytes).body
	if str(t, manual, "content_type") != "application/pdf" {
		t.Errorf("detected content type %q, want application/pdf", str(t, manual, "content_type"))
	}

	// The same content attached elsewhere is stored once.
	shelfPhoto := e.upload(t, 201, "/locations/"+garage+"/attachments", "garage.png", "image/png", pngBytes).body
	if str(t, shelfPhoto, "sha256") != pngHash {
		t.Error("the same content got a different hash")
	}
	if n := len(get(t, e.expect(t, 200, "GET", "/locations/"+garage, nil).body, "attachments").([]any)); n != 1 {
		t.Errorf("location_get has %d attachments, want 1", n)
	}
	e.upload(t, 201, "/classes/"+classID+"/attachments", "guide.pdf", "application/pdf", pdfBytes)

	// A new primary photo replaces the old one.
	second := e.upload(t, 201, "/items/"+itemID+"/attachments", "side.png", "image/png",
		append([]byte(nil), append(pngBytes, 'x')...), "primary_photo", "true").body
	if get(t, e.expect(t, 200, "GET", "/attachments/"+photoID, nil).body, "primary_photo") != false {
		t.Error("the old primary photo is still primary")
	}
	if str(t, e.expect(t, 200, "GET", "/items/"+itemID, nil).body, "photo", "id") != str(t, second, "id") {
		t.Error("item_get photo is not the new primary photo")
	}
	patched := e.expect(t, 200, "PATCH", "/attachments/"+photoID, obj("caption", nil, "file_name", "front-view.png")).body
	if get(t, patched, "caption") != nil || str(t, patched, "file_name") != "front-view.png" {
		t.Errorf("patch: %v", patched)
	}

	// Download.
	rec := e.raw("GET", "/attachments/"+photoID+"/content")
	if rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), pngBytes) {
		t.Fatalf("download: %d, %d bytes", rec.Code, rec.Body.Len())
	}
	if rec.Header().Get("Content-Type") != "image/png" ||
		!strings.HasPrefix(rec.Header().Get("Content-Disposition"), "inline") ||
		rec.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Errorf("download headers: %v", rec.Header())
	}
	if rec := e.raw("GET", "/attachments/"+photoID+"/content", "If-None-Match", rec.Header().Get("ETag")); rec.Code != 304 {
		t.Errorf("If-None-Match: %d, want 304", rec.Code)
	}
	page := e.upload(t, 201, "/items/"+itemID+"/attachments", "page.html", "text/html", htmlBytes).body
	rec = e.raw("GET", "/attachments/"+str(t, page, "id")+"/content")
	if !strings.HasPrefix(rec.Header().Get("Content-Disposition"), "attachment") {
		t.Errorf("HTML must be a download, got %q", rec.Header().Get("Content-Disposition"))
	}

	// Stock rows: a split copies the attachments; a row with attachments isn't merged away.
	e.upload(t, 201, "/stock/"+stockID+"/attachments", "receipt.pdf", "application/pdf", pdfBytes)
	split := e.expect(t, 200, "POST", "/stock/"+stockID+"/move", obj("location", van, "quantity", 1)).body
	if len(get(t, split, "attachments").([]any)) != 1 {
		t.Errorf("split-off row attachments: %v", get(t, split, "attachments"))
	}
	moved := e.expect(t, 200, "POST", "/stock/"+stockID+"/move", obj("location", van)).body
	if str(t, moved, "id") != stockID {
		t.Error("a row with attachments was merged away")
	}

	// Limits and format.
	e.upload(t, 413, "/items/"+itemID+"/attachments", "big.bin", "application/octet-stream",
		bytes.Repeat([]byte{1}, testMaxAttachment+1))
	e.expect(t, 415, "POST", "/items/"+itemID+"/attachments", obj("file", "x"))
	e.upload(t, 404, "/items/"+missing+"/attachments", "x.png", "image/png", pngBytes)

	// Garbage collection: the HTML file is only referenced by one attachment.
	htmlHash := str(t, page, "sha256")
	e.expect(t, 204, "DELETE", "/attachments/"+str(t, page, "id"), nil)
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
	if !e.fileExists(t, pngHash) {
		t.Error("gc removed a referenced file")
	}
	if rec := e.raw("GET", "/attachments/"+photoID+"/content"); rec.Code != http.StatusOK {
		t.Errorf("download after gc: %d", rec.Code)
	}
}
