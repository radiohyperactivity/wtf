package files

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"strings"
	"testing"
	"time"
)

// put stores content as a file and returns its hash.
func put(t *testing.T, s *Store, content []byte) string {
	t.Helper()
	staged, err := s.Stage(bytes.NewReader(content), 1<<30)
	if err != nil {
		t.Fatal(err)
	}
	if err := staged.Place(); err != nil {
		t.Fatal(err)
	}
	return staged.Hash
}

// halves is a w×h image, its left half red and its right half blue.
func halves(w, h int, alpha uint8) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := range h {
		for x := range w {
			c := color.NRGBA{R: 255, A: alpha}
			if x >= w/2 {
				c = color.NRGBA{B: 255, A: alpha}
			}
			img.SetNRGBA(x, y, c)
		}
	}
	return img
}

// withOrientation puts an Exif APP1 segment with orientation o after a
// JPEG's start marker.
func withOrientation(jpg []byte, o byte) []byte {
	tiff := []byte("MM\x00\x2a\x00\x00\x00\x08" + // big-endian, first directory at 8
		"\x00\x01" + // one entry
		"\x01\x12\x00\x03\x00\x00\x00\x01\x00" + string([]byte{o}) + "\x00\x00" + // orientation, SHORT
		"\x00\x00\x00\x00") // no next directory
	segment := append([]byte("Exif\x00\x00"), tiff...)
	n := len(segment) + 2
	app1 := append([]byte{0xFF, 0xE1, byte(n >> 8), byte(n)}, segment...)
	return append(append(append([]byte{}, jpg[:2]...), app1...), jpg[2:]...)
}

func encodeJPEG(t *testing.T, img image.Image) []byte {
	t.Helper()
	var b bytes.Buffer
	if err := jpeg.Encode(&b, img, &jpeg.Options{Quality: 95}); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func thumbnailOf(t *testing.T, s *Store, hash string, size int) (image.Image, string) {
	t.Helper()
	f, err := s.Thumbnail(hash, size)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	img, format, err := image.Decode(f)
	if err != nil {
		t.Fatal(err)
	}
	return img, format
}

func reddish(c color.Color) bool {
	r, _, b, _ := c.RGBA()
	return r > 0xc000 && b < 0x4000
}

func TestThumbnailSize(t *testing.T) {
	for asked, want := range map[int]int{1: 128, 128: 128, 129: 256, 288: 512, 1024: 1024} {
		if got, ok := ThumbnailSize(asked); !ok || got != want {
			t.Errorf("ThumbnailSize(%d) = %d, %v; want %d", asked, got, ok, want)
		}
	}
	if _, ok := ThumbnailSize(1025); ok {
		t.Error("ThumbnailSize(1025) should send the file itself")
	}
}

func TestThumbnailScalesAndTurns(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// 400 by 200, which the camera says is to be turned a quarter to the
	// right: upright, 200 wide and 400 high, the red half on top.
	hash := put(t, s, withOrientation(encodeJPEG(t, halves(400, 200, 255)), 6))
	img, format := thumbnailOf(t, s, hash, 128)
	if format != "jpeg" {
		t.Errorf("format %s, want jpeg", format)
	}
	if b := img.Bounds(); b.Dx() != 64 || b.Dy() != 128 {
		t.Fatalf("size %v, want 64×128", b.Size())
	}
	if !reddish(img.At(32, 20)) || reddish(img.At(32, 108)) {
		t.Error("not turned a quarter to the right: red should be on top")
	}

	// Made once: asked again, the same file is opened.
	p, _ := s.thumbnailPath(hash, 128)
	before, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	thumbnailOf(t, s, hash, 128)
	if after, _ := os.Stat(p); !after.ModTime().Equal(before.ModTime()) {
		t.Error("the thumbnail was made again")
	}
}

func TestThumbnailKeepsTransparency(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var b bytes.Buffer
	if err := png.Encode(&b, halves(600, 300, 128)); err != nil {
		t.Fatal(err)
	}
	img, format := thumbnailOf(t, s, put(t, s, b.Bytes()), 256)
	if format != "png" {
		t.Errorf("format %s, want png", format)
	}
	if b := img.Bounds(); b.Dx() != 256 || b.Dy() != 128 {
		t.Errorf("size %v, want 256×128", b.Size())
	}
	if _, _, _, a := img.At(10, 10).RGBA(); a > 0x9000 || a < 0x7000 {
		t.Errorf("alpha %#x, want about half", a)
	}
}

func TestNoThumbnail(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string][]byte{
		"not an image":       []byte("%PDF-1.7 not an image at all"),
		"smaller already":    encodeJPEG(t, halves(100, 60, 255)),
		"a damaged image":    encodeJPEG(t, halves(400, 200, 255))[:300],
		"an unknown picture": []byte(`<svg xmlns="http://www.w3.org/2000/svg"/>`),
	} {
		if _, err := s.Thumbnail(put(t, s, content), 128); !errors.Is(err, ErrNoThumbnail) {
			t.Errorf("%s: %v, want ErrNoThumbnail", name, err)
		}
	}
}

func TestThumbnailsGoWithTheirFile(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	jpg := encodeJPEG(t, halves(800, 600, 255))
	hash := put(t, s, jpg)
	thumbnailOf(t, s, hash, 128)
	thumbnailOf(t, s, hash, 256)
	if err := s.Remove(hash); err != nil {
		t.Fatal(err)
	}
	for _, size := range []int{128, 256} {
		p, _ := s.thumbnailPath(hash, size)
		if _, err := os.Stat(p); err == nil {
			t.Errorf("the %d thumbnail is still there", size)
		}
	}

	// One left behind, of a file that is gone, is swept up; one of a file
	// that is there is kept.
	gone := strings.Repeat("ab", 32)
	p, _ := s.thumbnailPath(gone, 128)
	if err := s.writeThumbnail(p, []byte("x")); err != nil {
		t.Fatal(err)
	}
	kept := put(t, s, jpg)
	thumbnailOf(t, s, kept, 128)
	n, _, err := s.RemoveOrphanThumbnails()
	if err != nil || n != 1 {
		t.Errorf("RemoveOrphanThumbnails: %d, %v; want 1", n, err)
	}
	if f, err := s.Thumbnail(kept, 128); err != nil {
		t.Errorf("the thumbnail of a file still there: %v", err)
	} else {
		f.Close()
	}

	// The thumbnails aren't files of their own.
	var walked []string
	if err := s.Walk(func(h string, _ time.Time) error { walked = append(walked, h); return nil }); err != nil {
		t.Fatal(err)
	}
	if len(walked) != 1 || walked[0] != kept {
		t.Errorf("Walk found %v, want only %s", walked, kept)
	}
}

func TestOrient(t *testing.T) {
	// A 3×2 image of distinct pixels, and where its top-left pixel (0, 0)
	// lands for each orientation.
	src := image.NewRGBA(image.Rect(0, 0, 3, 2))
	for y := range 2 {
		for x := range 3 {
			src.SetRGBA(x, y, color.RGBA{R: uint8(x), G: uint8(y), A: 255})
		}
	}
	corner := color.RGBA{A: 255}
	for o, want := range map[int]image.Point{
		1: {0, 0}, 2: {2, 0}, 3: {2, 1}, 4: {0, 1},
		5: {0, 0}, 6: {1, 0}, 7: {1, 2}, 8: {0, 2},
	} {
		dst := orient(src, o)
		if got := dst.RGBAAt(want.X, want.Y); got != corner {
			t.Errorf("orientation %d: %v at %v, want the top-left pixel", o, got, want)
		}
		if o >= 5 && (dst.Bounds().Dx() != 2 || dst.Bounds().Dy() != 3) {
			t.Errorf("orientation %d: size %v, want 2×3", o, dst.Bounds().Size())
		}
	}
}

// A phone photo's size, 4000 by 3000, to a list's thumbnail.
func BenchmarkThumbnail(b *testing.B) {
	img := image.NewRGBA(image.Rect(0, 0, 4000, 3000))
	for i := range img.Pix {
		img.Pix[i] = uint8(i * 7 % 251)
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 90}); err != nil {
		b.Fatal(err)
	}
	for b.Loop() {
		s, err := Open(b.TempDir())
		if err != nil {
			b.Fatal(err)
		}
		staged, _ := s.Stage(bytes.NewReader(buf.Bytes()), 1<<30)
		_ = staged.Place()
		f, err := s.Thumbnail(staged.Hash, 512)
		if err != nil {
			b.Fatal(err)
		}
		f.Close()
	}
}
