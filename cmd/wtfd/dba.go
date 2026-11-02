package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/jackc/pgx/v5"

	"github.com/radiohyperactivity/wtf/internal/admin"
	"github.com/radiohyperactivity/wtf/internal/config"
)

// parse parses an action's flags, which take no other arguments. It returns
// the exit code to stop with, and false, when parsing ends the action.
func parse(fs *flag.FlagSet, args []string, stderr io.Writer) (int, bool) {
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK, false
		}
		return exitUsage, false
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(stderr, "%s: unexpected argument %q\n", fs.Name(), fs.Arg(0))
		return exitUsage, false
	}
	return 0, true
}

// withDBA connects as the DBA role and runs fn, reporting its error.
func withDBA(database *config.Database, name string, stderr io.Writer, fn func(ctx context.Context, conn *pgx.Conn) error) int {
	if err := database.Validate(); err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", name, err)
		return exitUsage
	}
	connConfig, err := database.ConnConfig(database.DBAUser, os.Getenv(config.DBAPasswordEnv), name)
	if err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", name, err)
		return exitUsage
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	conn, err := admin.Connect(ctx, connConfig)
	if err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", name, err)
		return exitFailure
	}
	defer conn.Close(context.Background())
	if err := fn(ctx, conn); err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", name, err)
		return exitFailure
	}
	return exitOK
}
