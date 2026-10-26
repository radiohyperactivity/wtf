//go:build windows

package prompt

import (
	"os"

	"golang.org/x/sys/windows"
)

// EnableVT turns on escape-sequence processing for a Windows console.
func EnableVT(f *os.File) {
	h := windows.Handle(f.Fd())
	var mode uint32
	if windows.GetConsoleMode(h, &mode) == nil {
		_ = windows.SetConsoleMode(h, mode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
	}
}
