package config

import (
	"path/filepath"

	"golang.org/x/sys/windows"
)

// DefaultDir is where wtfd keeps its config and data on this system:
// ProgramData\WtF, as Windows reports ProgramData.
func DefaultDir() (string, error) {
	programData, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, 0)
	if err != nil {
		return "", err
	}
	return filepath.Join(programData, "WtF"), nil
}
