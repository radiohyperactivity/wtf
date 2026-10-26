// Package files stores attachment contents on disk, addressed by their
// SHA-256 hash: <directory>/<first two hex characters>/<hex hash>. A file
// never changes once stored, and the same content is stored only once.
//
// Uploads are written to <directory>/tmp first and renamed into place, so a
// half-written file never appears under a hash. Placing a file and
// recording it in the database happen under a per-hash advisory lock, which
// "wtfd gc" also takes before removing a file (see GC).
package files

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

// ErrTooLarge is returned by Stage when the content exceeds the limit.
var ErrTooLarge = errors.New("file too large")

var hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// Store is a files directory.
type Store struct {
	dir string
}

// Open opens the files directory, creating it (and its tmp directory) if
// needed.
func Open(dir string) (*Store, error) {
	if err := os.MkdirAll(filepath.Join(dir, "tmp"), 0o750); err != nil {
		return nil, fmt.Errorf("files directory: %w", err)
	}
	return &Store{dir: dir}, nil
}

// path returns where a file with the given hex hash is stored.
func (s *Store) path(hash string) (string, error) {
	if !hashPattern.MatchString(hash) {
		return "", fmt.Errorf("invalid file hash %q", hash)
	}
	return filepath.Join(s.dir, hash[:2], hash), nil
}

// OpenFile opens a stored file for reading.
func (s *Store) OpenFile(hash string) (*os.File, error) {
	p, err := s.path(hash)
	if err != nil {
		return nil, err
	}
	return os.Open(p)
}

// Remove deletes a stored file. A missing file is not an error.
func (s *Store) Remove(hash string) error {
	p, err := s.path(hash)
	if err != nil {
		return err
	}
	if err := os.Remove(p); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

// ModTime returns the modification time of a stored file, and false if it
// doesn't exist.
func (s *Store) ModTime(hash string) (time.Time, bool, error) {
	p, err := s.path(hash)
	if err != nil {
		return time.Time{}, false, err
	}
	info, err := os.Stat(p)
	if errors.Is(err, fs.ErrNotExist) {
		return time.Time{}, false, nil
	}
	if err != nil {
		return time.Time{}, false, err
	}
	return info.ModTime(), true, nil
}

// Staged is an uploaded file in the tmp directory, not yet in place.
type Staged struct {
	store *Store
	temp  string
	Hash  string // hex SHA-256 of the content
	Size  int64
	Head  []byte // the first (up to) 512 bytes, for content type detection
}

// Stage copies r into a temporary file while hashing it. Content larger than
// max bytes is rejected with ErrTooLarge.
func (s *Store) Stage(r io.Reader, max int64) (*Staged, error) {
	f, err := os.CreateTemp(filepath.Join(s.dir, "tmp"), "upload-*")
	if err != nil {
		return nil, err
	}
	staged := &Staged{store: s, temp: f.Name()}

	hash := sha256.New()
	head := &headWriter{limit: 512}
	n, err := io.Copy(io.MultiWriter(f, hash, head), io.LimitReader(r, max+1))
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	switch {
	case err != nil:
		staged.Discard()
		return nil, err
	case n > max:
		staged.Discard()
		return nil, ErrTooLarge
	}

	staged.Hash = hex.EncodeToString(hash.Sum(nil))
	staged.Size = n
	staged.Head = head.data
	return staged, nil
}

// Place moves the staged file to its place in the store. If the same content
// is already stored, the staged copy is dropped and the stored file's
// modification time is refreshed, so "wtfd gc" treats it as new. Call it
// while holding the hash's advisory lock (attachment_lock).
func (st *Staged) Place() error {
	final, err := st.store.path(st.Hash)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(final), 0o750); err != nil {
		return err
	}
	now := time.Now()
	switch err := os.Chtimes(final, now, now); {
	case err == nil:
		st.Discard()
		return nil
	case !errors.Is(err, fs.ErrNotExist):
		return err
	}
	return os.Rename(st.temp, final)
}

// Discard removes the staged file, if it is still in the tmp directory.
func (st *Staged) Discard() {
	_ = os.Remove(st.temp)
}

// Walk calls fn for every stored file.
func (s *Store) Walk(fn func(hash string, modTime time.Time) error) error {
	return filepath.WalkDir(s.dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if p != s.dir && d.Name() == "tmp" {
				return filepath.SkipDir
			}
			return nil
		}
		if !hashPattern.MatchString(d.Name()) {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		return fn(d.Name(), info.ModTime())
	})
}

// TempFiles calls fn for every file in the tmp directory.
func (s *Store) TempFiles(fn func(path string, modTime time.Time) error) error {
	entries, err := os.ReadDir(filepath.Join(s.dir, "tmp"))
	if err != nil {
		return err
	}
	for _, e := range entries {
		info, err := e.Info()
		if err != nil {
			return err
		}
		if err := fn(filepath.Join(s.dir, "tmp", e.Name()), info.ModTime()); err != nil {
			return err
		}
	}
	return nil
}

// headWriter keeps the first limit bytes written to it.
type headWriter struct {
	data  []byte
	limit int
}

func (h *headWriter) Write(p []byte) (int, error) {
	if room := h.limit - len(h.data); room > 0 {
		h.data = append(h.data, p[:min(room, len(p))]...)
	}
	return len(p), nil
}
