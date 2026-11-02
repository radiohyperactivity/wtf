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
)

// The client keeps a cache per server, in the user's cache directory or
// $WTF_CACHE_DIR: the class and location trees, revalidated on every use
// with their version (ETag), which costs the server one row lookup. A
// change made by this client refreshes what it makes outdated at once (see
// wrote). The classes with their attributes are fetched once per run.

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

func (e *env) readCache(name string, v any) bool {
	dir := e.cacheDir()
	if dir == "" {
		return false
	}
	data, err := os.ReadFile(filepath.Join(dir, name+".json"))
	return err == nil && decode(data, v) == nil
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

// wrote is called after a successful change at path. It drops this run's
// copies the change makes outdated, so the next use fetches them again (the
// cached trees are revalidated anyway).
func (e *env) wrote(path string) {
	switch {
	case strings.HasPrefix(path, "/locations"):
		e.cache.locations = nil
	case strings.HasPrefix(path, "/classes"), strings.HasPrefix(path, "/model"):
		e.cache.classes, e.cache.details = nil, nil
	}
}

// cachedTree fetches a class or location tree, sending the cached version so
// an unchanged tree comes back as 304 Not Modified.
func (e *env) cachedTree(path, name string) (tree, error) {
	var cached tree
	have := e.readCache(name, &cached)
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
