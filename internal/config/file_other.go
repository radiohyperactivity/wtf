//go:build !windows

package config

import "runtime"

// DefaultDir is where wtfd keeps its config on this system: /etc/wtf, or
// on macOS /Library/Application Support/WtF.
func DefaultDir() (string, error) {
	if runtime.GOOS == "darwin" {
		return "/Library/Application Support/WtF", nil
	}
	return "/etc/wtf", nil
}
