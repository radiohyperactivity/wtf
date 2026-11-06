package config

import (
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
)

// wtfd's config file has a setting on each line, "key = value", with
// wtfd's flag names as keys; lines starting with # are comments. A flag
// wins over its environment variable, which wins over the file, which wins
// over the built-in default. Passwords are never in it: they are in
// PostgreSQL's password file, pgpass.conf, beside it.
const (
	FileName       = "wtfd.conf"
	ConfigEnv      = "WTFD_CONFIG"
	PasswordFile   = "pgpass.conf"
	passFileEnv    = "PGPASSFILE"
	settingComment = "#"
)

// Setting is a line of the config file.
type Setting struct {
	Key, Value string
	Line       int // in the file, from 1; 0 for a setting not read from one
}

// ParseFile reads the settings in text.
func ParseFile(text string) ([]Setting, error) {
	var settings []Setting
	seen := map[string]int{}
	for i, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, settingComment) {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		key, value = strings.TrimSpace(key), strings.TrimSpace(value)
		if !ok || key == "" {
			return nil, fmt.Errorf("line %d: not a setting; write key = value", i+1)
		}
		if first, ok := seen[key]; ok {
			return nil, fmt.Errorf("line %d: %s is set on line %d already", i+1, key, first)
		}
		seen[key] = i + 1
		settings = append(settings, Setting{Key: key, Value: value, Line: i + 1})
	}
	return settings, nil
}

// ReadFile reads the settings in the file at path.
func ReadFile(path string) ([]Setting, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	settings, err := ParseFile(string(b))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return settings, nil
}

// UpdateFile returns the file's text old with settings in it: a key it has
// already gets the new value in its place, others are added at the end,
// and the other lines, comments among them, stay as they were. header
// starts a file that was empty.
func UpdateFile(old, header string, settings []Setting) string {
	pending := map[string]string{}
	for _, s := range settings {
		pending[s.Key] = s.Value
	}
	var out []string
	if old = strings.TrimRight(strings.ReplaceAll(old, "\r\n", "\n"), "\n"); old != "" {
		for _, line := range strings.Split(old, "\n") {
			trimmed := strings.TrimSpace(line)
			if key, _, ok := strings.Cut(trimmed, "="); ok && !strings.HasPrefix(trimmed, settingComment) {
				key = strings.TrimSpace(key)
				if value, ok := pending[key]; ok {
					line = key + " = " + value
					delete(pending, key)
				}
			}
			out = append(out, line)
		}
	} else if header != "" {
		out = append(out, strings.Split(strings.TrimRight(header, "\n"), "\n")...)
	}
	for _, s := range settings {
		if value, ok := pending[s.Key]; ok {
			out = append(out, s.Key+" = "+value)
		}
	}
	return strings.Join(out, "\n") + "\n"
}

// EnvName is the environment variable of the setting key.
func EnvName(key string) string {
	if key == "min-age" {
		return "WTFD_GC_MIN_AGE"
	}
	return "WTFD_" + strings.ToUpper(strings.ReplaceAll(key, "-", "_"))
}

// settingKeys are the flags of every action that a config file may set:
// those of the Register functions here, not an action's own (--dry-run,
// --verbose).
var settingKeys = sync.OnceValue(func() []string {
	fs := flag.NewFlagSet("settings", flag.ContinueOnError)
	RegisterDatabase(fs)
	RegisterFiles(fs)
	RegisterGC(fs)
	RegisterServe(fs)
	var keys []string
	fs.VisitAll(func(f *flag.Flag) { keys = append(keys, f.Name) })
	return keys
})

// File is where an action's config file is, and whether it was read.
type File struct {
	Path string // "" for none
	Read bool

	given bool // named by --config or WTFD_CONFIG, so it must be there
}

// RegisterFile adds --config to fs. Its default is WTFD_CONFIG, or else
// the file in this system's place for it (DefaultDir).
func RegisterFile(fs *flag.FlagSet) *File {
	f := &File{}
	path, given := os.LookupEnv(ConfigEnv)
	if !given {
		if dir, err := DefaultDir(); err == nil {
			path = filepath.Join(dir, FileName)
		}
	}
	f.given = given
	fs.StringVar(&f.Path, "config", path, "wtfd's config file; --config= for none (env "+ConfigEnv+")")
	return f
}

// Apply reads the config file, after fs is parsed, and gives fs's flags the
// values it has for them, unless the command line or an environment
// variable gave one. A file at the default place may be missing; one that
// can't be read is reported on warn, and gone without. When the file is
// read and PGPASSFILE isn't set, the password file beside it is used.
func (f *File) Apply(flags *flag.FlagSet, warn func(string)) error {
	flags.Visit(func(fl *flag.Flag) {
		if fl.Name == "config" {
			f.given = true
		}
	})
	if f.Path == "" {
		return nil
	}
	settings, err := ReadFile(f.Path)
	switch {
	case err == nil:
	case !f.given && errors.Is(err, fs.ErrNotExist):
		return nil
	case !f.given && errors.Is(err, fs.ErrPermission):
		warn(fmt.Sprintf("can't read %s, which is for administrators; going on without it (run as an administrator to use it)", f.Path))
		return nil
	default:
		return err
	}

	given := map[string]bool{}
	flags.Visit(func(fl *flag.Flag) { given[fl.Name] = true })
	for _, s := range settings {
		if !slices.Contains(settingKeys(), s.Key) {
			return fmt.Errorf("%s, line %d: %s isn't a setting of wtfd's", f.Path, s.Line, s.Key)
		}
		if flags.Lookup(s.Key) == nil || given[s.Key] {
			continue
		}
		if _, ok := os.LookupEnv(EnvName(s.Key)); ok {
			continue
		}
		if err := flags.Set(s.Key, s.Value); err != nil {
			return fmt.Errorf("%s, line %d: %s: %w", f.Path, s.Line, s.Key, err)
		}
	}
	f.Read = true

	if _, ok := os.LookupEnv(passFileEnv); !ok {
		passFile := filepath.Join(filepath.Dir(f.Path), PasswordFile)
		if _, err := os.Stat(passFile); err == nil {
			os.Setenv(passFileEnv, passFile)
		}
	}
	return nil
}

// SetFrom gives fs's flags that the command line didn't give the values
// settings has for them, ignoring the environment, and the keys fs hasn't.
// It is for "wtfd install", which takes its defaults from the file it
// writes.
func SetFrom(fs *flag.FlagSet, settings []Setting) error {
	given := map[string]bool{}
	fs.Visit(func(fl *flag.Flag) { given[fl.Name] = true })
	for _, s := range settings {
		if fs.Lookup(s.Key) == nil || given[s.Key] {
			continue
		}
		if err := fs.Set(s.Key, s.Value); err != nil {
			return fmt.Errorf("line %d: %s: %w", s.Line, s.Key, err)
		}
	}
	return nil
}
