package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
)

// Profile is one server login.
type Profile struct {
	Server string `json:"server"`
	Email  string `json:"email,omitempty"`
	Token  string `json:"token,omitempty"`
}

// Config is the client configuration file: named profiles and the current one.
type Config struct {
	Current  string              `json:"current"`
	Profiles map[string]*Profile `json:"profiles"`

	path string
}

// configPath is $WTF_CONFIG, or wtf/config.json in the user's config directory.
func configPath(getenv func(string) string) (string, error) {
	if p := getenv("WTF_CONFIG"); p != "" {
		return p, nil
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "wtf", "config.json"), nil
}

// loadConfig reads the configuration; a missing file is an empty one.
func loadConfig(getenv func(string) string) (*Config, error) {
	path, err := configPath(getenv)
	if err != nil {
		return nil, err
	}
	c := &Config{Profiles: map[string]*Profile{}, path: path}
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return c, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, c); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if c.Profiles == nil {
		c.Profiles = map[string]*Profile{}
	}
	return c, nil
}

// save writes the configuration, readable only by the user (it holds tokens).
func (c *Config) save() error {
	if err := os.MkdirAll(filepath.Dir(c.path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, c.path)
}

// profileNames returns the profile names, sorted.
func (c *Config) profileNames() []string {
	var names []string
	for n := range c.Profiles {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}
