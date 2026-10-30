package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"text/tabwriter"

	"github.com/jackc/pgx/v5"

	"github.com/radiohyperactivity/wtf/internal/admin"
	"github.com/radiohyperactivity/wtf/internal/config"
	"github.com/radiohyperactivity/wtf/internal/files"
)

const tenantUsage = `Usage:
  wtfd tenant create --host HOST --email EMAIL [database flags]
  wtfd tenant list [database flags]
  wtfd tenant rename --host HOST --new-host NEW --files-directory DIR [database flags]

create makes a tenant and its first account, an admin, and
prints the account's generated password once. HOST is the first label of the
hostnames that reach the tenant: "bob" for bob.wtf.example. rename changes
it, and moves the tenant's directory in the files directory along.
`

func runTenant(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, tenantUsage)
		return exitUsage
	}
	command := args[0]
	switch command {
	case "create", "list", "rename":
	case "help", "-h", "-help", "--help":
		fmt.Fprint(stderr, tenantUsage)
		return exitOK
	default:
		fmt.Fprintf(stderr, "wtfd tenant: unknown command %q\n\n%s", command, tenantUsage)
		return exitUsage
	}
	name := "wtfd tenant " + command
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(stderr)
	database := config.RegisterDatabase(fs)
	var host, email, newHost *string
	var filesDir *config.Files
	if command != "list" {
		host = fs.String("host", "", "the tenant's host (required)")
	}
	switch command {
	case "create":
		email = fs.String("email", "", "the first account's email (required)")
	case "rename":
		newHost = fs.String("new-host", "", "the new host (required)")
		filesDir = config.RegisterFiles(fs)
	}
	if code, ok := parse(fs, args[1:], stderr); !ok {
		return code
	}
	missing := (host != nil && *host == "") || (email != nil && *email == "") || (newHost != nil && *newHost == "")
	if missing {
		fmt.Fprintf(stderr, "%s: missing flags\n\n%s", name, tenantUsage)
		return exitUsage
	}
	if filesDir != nil {
		if err := filesDir.Validate(); err != nil {
			fmt.Fprintf(stderr, "%s: %v\n", name, err)
			return exitUsage
		}
	}

	return withDBA(database, name, stderr, func(ctx context.Context, conn *pgx.Conn) error {
		switch command {
		case "create":
			password, err := admin.CreateTenant(ctx, conn, *host, *email)
			if err != nil {
				return err
			}
			fmt.Fprintf(stdout, "Tenant %s created, with the account %s, an admin.\n", *host, *email)
			fmt.Fprintf(stdout, "Password: %s\n", password)
			fmt.Fprintln(stdout, "The password is shown only this once; change it after logging in (PUT /me/password).")
		case "list":
			tenants, err := admin.ListTenants(ctx, conn)
			if err != nil {
				return err
			}
			w := tabwriter.NewWriter(stdout, 0, 0, 2, ' ', 0)
			fmt.Fprintln(w, "HOST\tACCOUNTS\tITEMS\tFILES")
			for _, t := range tenants {
				fmt.Fprintf(w, "%s\t%d\t%d\t%d\n", t.Host, t.Accounts, t.Items, t.Files)
			}
			return w.Flush()
		case "rename":
			store, err := files.Open(filesDir.Directory)
			if err != nil {
				return err
			}
			if err := admin.RenameTenant(ctx, conn, store, *host, *newHost); err != nil {
				return err
			}
			fmt.Fprintf(stdout, "Tenant %s is now %s.\n", *host, *newHost)
		}
		return nil
	})
}

const unitUsage = `Usage:
  wtfd unit import --global FILE [--dry-run] [database flags]
  wtfd unit standard (--quantity NAME | --family NAME) --available true|false [database flags]

import adds the units of a model file of only quantities
(seed/model-format.md) as global units, which every tenant sees. standard sets whether a global quantity or
unit family is available to tenants that haven't chosen themselves.
`

func runUnit(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, unitUsage)
		return exitUsage
	}
	command := args[0]
	switch command {
	case "import", "standard":
	case "help", "-h", "-help", "--help":
		fmt.Fprint(stderr, unitUsage)
		return exitOK
	default:
		fmt.Fprintf(stderr, "wtfd unit: unknown command %q\n\n%s", command, unitUsage)
		return exitUsage
	}
	name := "wtfd unit " + command
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(stderr)
	database := config.RegisterDatabase(fs)
	var file, quantity, family, available *string
	var dryRun *bool
	if command == "import" {
		file = fs.String("global", "", "the model file (of only quantities) to import as global units (required)")
		dryRun = fs.Bool("dry-run", false, "report what would be added, add nothing")
	} else {
		quantity = fs.String("quantity", "", "a global quantity, by name")
		family = fs.String("family", "", "a global unit family, by name")
		available = fs.String("available", "", "true or false (required)")
	}
	if code, ok := parse(fs, args[1:], stderr); !ok {
		return code
	}

	if command == "import" {
		if *file == "" {
			fmt.Fprintf(stderr, "%s: --global FILE is required (tenants import their own units through the API)\n", name)
			return exitUsage
		}
		data, err := os.ReadFile(*file)
		if err != nil {
			fmt.Fprintf(stderr, "%s: %v\n", name, err)
			return exitFailure
		}
		return withDBA(database, name, stderr, func(ctx context.Context, conn *pgx.Conn) error {
			report, err := admin.ImportGlobalUnits(ctx, conn, data, *dryRun)
			if err != nil {
				return err
			}
			_, err = fmt.Fprintf(stdout, "%s\n", report)
			return err
		})
	}

	value, err := strconv.ParseBool(*available)
	if err != nil || (*quantity == "") == (*family == "") {
		fmt.Fprintf(stderr, "%s: give --quantity or --family, and --available true or false\n", name)
		return exitUsage
	}
	kind, target := "quantity", *quantity
	if *family != "" {
		kind, target = "family", *family
	}
	return withDBA(database, name, stderr, func(ctx context.Context, conn *pgx.Conn) error {
		if err := admin.SetUnitStandard(ctx, conn, kind, target, value); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "%s is now available as standard: %t.\n", target, value)
		return nil
	})
}

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
