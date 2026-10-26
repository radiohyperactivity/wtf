// Command wtf is the command-line client of WtF. See CLI.md.
package main

import (
	"os"

	"github.com/radiohyperactivity/wtf/internal/cli"
)

func main() {
	os.Exit(cli.Main())
}
