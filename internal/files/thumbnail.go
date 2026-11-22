package files

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	// The image formats a thumbnail is made from.
	_ "image/gif"

	_ "golang.org/x/image/bmp"
	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

// Thumbnails are smaller copies of stored images, for lists, where a photo
// is shown a few dozen pixels wide. They are made when first asked for and
// kept in <directory>/thumbnails/<first two hex characters>/<hex
// hash>-<size>: the image scaled to fit in a box of size pixels on a side,
// turned upright as its Exif orientation says, as JPEG (PNG when it has
// transparency). They can be deleted at any time, and are made again.

// ThumbnailSizes are the box sizes thumbnails are made in. A size asked for
// is rounded up to one of them, so that there are at most this many
// thumbnails of a file.
var ThumbnailSizes = []int{128, 256, 512, 1024}

// thumbnailDir is the directory of the thumbnails in the files directory.
const thumbnailDir = "thumbnails"

// maxThumbnailPixels is the largest image a thumbnail is made of: decoding
// takes a few bytes a pixel.
const maxThumbnailPixels = 64_000_000

// ErrNoThumbnail is returned by Thumbnail for a file there is no thumbnail
// of: not an image of a format it knows, already as small as the size,
// larger than it decodes, or damaged. The file itself is to be sent.
var ErrNoThumbnail = errors.New("no thumbnail")

// ThumbnailSize is the size of the thumbnail to send for a request of
// size pixels: the smallest of ThumbnailSizes as large, and false when
// size is larger than all of them.
func ThumbnailSize(size int) (int, bool) {
	for _, s := range ThumbnailSizes {
		if size <= s {
			return s, true
		}
	}
	return 0, false
}

// thumbnailPath is where the thumbnail of the given size of a file is kept.
func (s *Store) thumbnailPath(hash string, size int) (string, error) {
	if !hashPattern.MatchString(hash) {
		return "", fmt.Errorf("invalid file hash %q", hash)
	}
	return filepath.Join(s.dir, thumbnailDir, hash[:2], hash+"-"+strconv.Itoa(size)), nil
}

// Thumbnail opens the thumbnail of the file with hash, of size, one of
// ThumbnailSizes; it is made first if there isn't one yet. For a file there
// is no thumbnail of, it returns ErrNoThumbnail.
func (s *Store) Thumbnail(hash string, size int) (*os.File, error) {
	p, err := s.thumbnailPath(hash, size)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(p)
	if !errors.Is(err, fs.ErrNotExist) {
		return f, err
	}
	// The same thumbnail asked for twice at once is made once, and only a
	// few are made at a time, as each takes the memory of its image.
	_, err, _ = s.making.Do(p, func() (any, error) {
		s.makers <- struct{}{}
		defer func() { <-s.makers }()
		return nil, s.makeThumbnail(hash, size, p)
	})
	if err != nil {
		return nil, err
	}
	return os.Open(p)
}

// makeThumbnail writes the thumbnail of the file with hash, of size, to p.
func (s *Store) makeThumbnail(hash string, size int, p string) error {
	if _, err := os.Stat(p); err == nil {
		return nil // made while this one waited its turn
	}
	src, err := s.OpenFile(hash)
	if err != nil {
		return err
	}
	defer src.Close()

	config, format, err := image.DecodeConfig(src)
	if err != nil {
		return ErrNoThumbnail
	}
	if !strings.Contains(" jpeg png gif webp bmp ", " "+format+" ") ||
		config.Width <= size && config.Height <= size ||
		int64(config.Width)*int64(config.Height) > maxThumbnailPixels {
		return ErrNoThumbnail
	}
	orientation := 1
	if format == "jpeg" {
		if _, err := src.Seek(0, io.SeekStart); err != nil {
			return err
		}
		orientation = jpegOrientation(src)
	}
	if _, err := src.Seek(0, io.SeekStart); err != nil {
		return err
	}
	img, _, err := image.Decode(src)
	if err != nil {
		return ErrNoThumbnail
	}

	b := img.Bounds()
	scale := float64(size) / float64(max(b.Dx(), b.Dy()))
	w := max(1, int(float64(b.Dx())*scale+0.5))
	h := max(1, int(float64(b.Dy())*scale+0.5))
	small := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.BiLinear.Scale(small, small.Bounds(), img, b, draw.Src, nil)
	upright := orient(small, orientation)

	var out bytes.Buffer
	if o, ok := img.(interface{ Opaque() bool }); ok && !o.Opaque() {
		err = png.Encode(&out, upright)
	} else {
		err = jpeg.Encode(&out, upright, &jpeg.Options{Quality: 82})
	}
	if err != nil {
		return err
	}
	return s.writeThumbnail(p, out.Bytes())
}

// writeThumbnail puts a thumbnail in place through the tmp directory, so
// that a half-written one never appears.
func (s *Store) writeThumbnail(p string, content []byte) error {
	if err := os.MkdirAll(filepath.Join(s.dir, "tmp"), 0o750); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Join(s.dir, "tmp"), "thumbnail-*")
	if err != nil {
		return err
	}
	_, err = f.Write(content)
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(f.Name(), p)
	}
	if err != nil {
		_ = os.Remove(f.Name())
	}
	return err
}

// removeThumbnails deletes the thumbnails of the file with hash.
func (s *Store) removeThumbnails(hash string) error {
	for _, size := range ThumbnailSizes {
		p, err := s.thumbnailPath(hash, size)
		if err != nil {
			return err
		}
		if err := os.Remove(p); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
	}
	return nil
}

// RemoveOrphanThumbnails deletes the thumbnails whose file is gone (left
// when removing them failed), and reports how many there were and their
// bytes.
func (s *Store) RemoveOrphanThumbnails() (int, int64, error) {
	root := filepath.Join(s.dir, thumbnailDir)
	count, size := 0, int64(0)
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if errors.Is(err, fs.ErrNotExist) && p == root {
			return filepath.SkipDir
		}
		if err != nil || d.IsDir() {
			return err
		}
		hash, _, _ := strings.Cut(d.Name(), "-")
		if _, ok, err := s.ModTime(hash); err != nil || ok {
			return nil // a file that is still there, or a name that isn't a thumbnail's
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		if err := os.Remove(p); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		count++
		size += info.Size()
		return nil
	})
	return count, size, err
}

// jpegOrientation is the Exif orientation of a JPEG image (1 to 8: how to
// turn it upright), read from its APP1 segment; 1, as it is, when there is
// none.
func jpegOrientation(r io.Reader) int {
	br := &byteReader{r: r}
	if br.u16(binary.BigEndian) != 0xFFD8 {
		return 1
	}
	for br.err == nil {
		marker := br.u16(binary.BigEndian)
		if marker&0xFF00 != 0xFF00 || marker == 0xFFDA { // start of scan: no more metadata
			return 1
		}
		length := int(br.u16(binary.BigEndian)) - 2
		if length < 0 {
			return 1
		}
		segment := br.bytes(length)
		if marker == 0xFFE1 && bytes.HasPrefix(segment, []byte("Exif\x00\x00")) {
			return exifOrientation(segment[6:])
		}
	}
	return 1
}

// exifOrientation reads the orientation tag (0x0112) of the first image
// directory of Exif data (a TIFF structure).
func exifOrientation(tiff []byte) int {
	if len(tiff) < 8 {
		return 1
	}
	var order binary.ByteOrder
	switch string(tiff[:2]) {
	case "II":
		order = binary.LittleEndian
	case "MM":
		order = binary.BigEndian
	default:
		return 1
	}
	ifd := int(order.Uint32(tiff[4:8]))
	if ifd < 8 || ifd+2 > len(tiff) {
		return 1
	}
	entries := int(order.Uint16(tiff[ifd:]))
	for i := range entries {
		e := ifd + 2 + 12*i
		if e+12 > len(tiff) {
			return 1
		}
		if order.Uint16(tiff[e:]) == 0x0112 {
			if v := int(order.Uint16(tiff[e+8:])); v >= 1 && v <= 8 {
				return v
			}
			return 1
		}
	}
	return 1
}

// byteReader reads big- or little-endian numbers and runs of bytes,
// remembering the first error.
type byteReader struct {
	r   io.Reader
	err error
}

func (b *byteReader) bytes(n int) []byte {
	buf := make([]byte, n)
	if b.err == nil {
		_, b.err = io.ReadFull(b.r, buf)
	}
	return buf
}

func (b *byteReader) u16(order binary.ByteOrder) uint16 {
	return order.Uint16(b.bytes(2))
}

// orient turns an image as Exif orientation o says, so that it is upright:
// 2 to 8 are mirrored, turned, or both.
func orient(src *image.RGBA, o int) *image.RGBA {
	if o < 2 || o > 8 {
		return src
	}
	w, h := src.Bounds().Dx(), src.Bounds().Dy()
	dw, dh := w, h
	if o >= 5 { // turned a quarter: width and height swap
		dw, dh = h, w
	}
	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	for y := range dh {
		for x := range dw {
			var sx, sy int
			switch o {
			case 2: // mirrored
				sx, sy = w-1-x, y
			case 3: // upside down
				sx, sy = w-1-x, h-1-y
			case 4: // mirrored upside down
				sx, sy = x, h-1-y
			case 5: // mirrored, a quarter turn
				sx, sy = y, x
			case 6: // a quarter turn to the right
				sx, sy = y, h-1-x
			case 7: // mirrored, a quarter turn the other way
				sx, sy = w-1-y, h-1-x
			case 8: // a quarter turn to the left
				sx, sy = w-1-y, x
			}
			dst.SetRGBA(x, y, src.RGBAAt(sx, sy))
		}
	}
	return dst
}
