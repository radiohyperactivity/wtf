//go:build !windows

package main

import (
	"fmt"
	"io"
	"os"
)

func runInstall(_ []string, _ *os.File, _, stderr io.Writer) int {
	fmt.Fprint(stderr, "wtfd install is only for Windows so far.\n")
	return exitUsage
}

func runServiceCommand(_ []string, _ *os.File, _, stderr io.Writer) int {
	fmt.Fprint(stderr, "wtfd service is only for Windows so far.\n")
	return exitUsage
}
