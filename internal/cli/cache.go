package cli

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The client keeps a cache per server (and so per tenant), in the user's cache
// directory or $WTF_CACHE_DIR:
//
//   - the class and location trees, revalidated on every use with their
//     version (ETag), which costs the server one row lookup;
//   - while completing on the command line, the lists of attributes, unit
//     groups, quantities and units, for a minute.
//
// A change made by this client refreshes what it makes outdated at once (see
// wrote). Unit groups, quantities and units can't be changed through the API.

const listTTL = time.Minute

// cacheDir returns the cache directory for the current server, or "".
func (e *env) cacheDir() string {
	if e.api == nil || e.api.Server == "" {
		return ""
	}
	base := e.getenv("WTF_CACHE_DIR")
	if base == "" {
		dir, err := os.UserCacheDir()
		if err != nil {
			return ""
		}
		base = filepath.Join(dir, "wtf")
	}
	sum := sha256.Sum256([]byte(e.api.Server))
	return filepath.Join(base, hex.EncodeToString(sum[:8]))
}

func (e *env) readCache(name string, v any) (time.Time, bool) {
	dir := e.cacheDir()
	if dir == "" {
		return time.Time{}, false
	}
	path := filepath.Join(dir, name+".json")
	fi, err := os.Stat(path)
	if err != nil {
		return time.Time{}, false
	}
	data, err := os.ReadFile(path)
	if err != nil || decode(data, v) != nil {
		return time.Time{}, false
	}
	return fi.ModTime(), true
}

// writeCache stores v; failures only cost speed, so they are ignored.
func (e *env) writeCache(name string, v any) {
	dir := e.cacheDir()
	if dir == "" {
		return
	}
	data, err := json.Marshal(v)
	if err != nil || os.MkdirAll(dir, 0o700) != nil {
		return
	}
	tmp := filepath.Join(dir, name+".json.tmp")
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, filepath.Join(dir, name+".json"))
	}
}

// wrote is called after a successful change at path. It drops the copies
// the change makes outdated, so the next use fetches them again: this run's
// tree (the cached file is revalidated anyway), or the attributes, including
// the list kept for completion.
func (e *env) wrote(path string) {
	switch {
	case strings.HasPrefix(path, "/locations"):
		e.cache.locations = nil
	case strings.HasPrefix(path, "/classes"):
		e.cache.classes = nil
	case strings.HasPrefix(path, "/attributes"), strings.HasPrefix(path, "/options"):
		e.cache.attributes = nil
		if dir := e.cacheDir(); dir != "" {
			_ = os.Remove(filepath.Join(dir, "attributes.json"))
		}
	}
}

// cachedTree fetches a class or location tree, sending the cached version so
// an unchanged tree comes back as 304 Not Modified.
func (e *env) cachedTree(path, name string) (tree, error) {
	var cached tree
	_, have := e.readCache(name, &cached)
	var headers []string
	if have {
		headers = []string{"If-None-Match", fmt.Sprintf(`"%d"`, cached.Version)}
	}
	data, _, err := e.api.Do(e.ctx, http.MethodGet, path, nil, nil, headers...)
	if err != nil {
		return tree{}, err
	}
	if data == nil && have {
		return cached, nil
	}
	var t tree
	if err := decode(data, &t); err != nil {
		return tree{}, err
	}
	e.writeCache(name, t)
	return t, nil
}

// cachedGet fetches a small list; while completing, a copy younger than
// listTTL is used instead.
func (e *env) cachedGet(path, name string, v any) error {
	if e.completing {
		if at, ok := e.readCache(name, v); ok && time.Since(at) < listTTL {
			return nil
		}
	}
	data, err := e.api.Get(e.ctx, path, nil)
	if err != nil {
		return err
	}
	if err := decode(data, v); err != nil {
		return err
	}
	if e.completing {
		var raw json.RawMessage = data
		e.writeCache(name, raw)
	}
	return nil
}
