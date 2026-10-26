package schema

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"maps"
	"path"
	"regexp"
	"strconv"
	"strings"
)

// script is one embedded SQL file.
type script struct {
	name     string // file name, e.g. "0001_schema.sql"
	version  int    // migrations only
	sql      string // content with LF line endings
	checksum []byte // SHA-256 of sql
}

var (
	migrationName  = regexp.MustCompile(`^(\d{4})_[a-z0-9_]+\.sql$`)
	repeatableName = regexp.MustCompile(`^\d{2}_[a-z0-9_]+\.sql$`)
)

// loadScripts reads the migrations (versions 1, 2, … without gaps) and the
// repeatable scripts, both in file-name order.
func loadScripts(fsys fs.FS) (migrations, repeatables []script, err error) {
	migrations, err = readScripts(fsys, "migrations", migrationName)
	if err != nil {
		return nil, nil, err
	}
	for i := range migrations {
		m := &migrations[i]
		m.version, _ = strconv.Atoi(migrationName.FindStringSubmatch(m.name)[1])
		if m.version != i+1 {
			return nil, nil, fmt.Errorf("migrations/%s: expected version %04d", m.name, i+1)
		}
	}

	repeatables, err = readScripts(fsys, "repeatable", repeatableName)
	if err != nil {
		return nil, nil, err
	}
	return migrations, repeatables, nil
}

// Fingerprint identifies a schema: the migration version and the checksums
// (hex SHA-256) of the repeatable scripts. It matches the JSON returned by the
// database function schema_version().
type Fingerprint struct {
	Version     int               `json:"version"`
	Repeatables map[string]string `json:"repeatables"`
}

// Expected returns the fingerprint of the scripts in fsys, i.e. what the
// database looks like after "wtfd schema" has run.
func Expected(fsys fs.FS) (Fingerprint, error) {
	migrations, repeatables, err := loadScripts(fsys)
	if err != nil {
		return Fingerprint{}, err
	}
	f := Fingerprint{Version: len(migrations), Repeatables: map[string]string{}}
	for _, r := range repeatables {
		f.Repeatables[r.name] = hex.EncodeToString(r.checksum)
	}
	return f, nil
}

// Equal reports whether f and g describe the same schema.
func (f Fingerprint) Equal(g Fingerprint) bool {
	return f.Version == g.Version && maps.Equal(f.Repeatables, g.Repeatables)
}

func readScripts(fsys fs.FS, dir string, pattern *regexp.Regexp) ([]script, error) {
	entries, err := fs.ReadDir(fsys, dir) // sorted by file name
	if err != nil {
		return nil, err
	}

	var scripts []script
	for _, e := range entries {
		if !pattern.MatchString(e.Name()) {
			return nil, fmt.Errorf("%s/%s: file name does not match %s", dir, e.Name(), pattern)
		}
		content, err := fs.ReadFile(fsys, path.Join(dir, e.Name()))
		if err != nil {
			return nil, err
		}
		// A Windows checkout may have CRLF line endings; normalise so the
		// checksum is the same everywhere.
		sql := strings.ReplaceAll(string(content), "\r\n", "\n")
		sum := sha256.Sum256([]byte(sql))
		scripts = append(scripts, script{name: e.Name(), sql: sql, checksum: sum[:]})
	}
	return scripts, nil
}
