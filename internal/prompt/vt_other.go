//go:build !windows

package prompt

import "os"

// EnableVT is needed only on Windows; other terminals understand escape
// sequences.
func EnableVT(*os.File) {}
