//go:build !windows

package main

// runService runs wtfd as a Windows service, which it never is here.
func runService([]string) (int, bool) {
	return 0, false
}
