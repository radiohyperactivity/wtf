// Command wtfd is the WtF server. Its first argument is an action:
//
//	wtfd schema [flags]    create or upgrade the database schema
//	wtfd serve [flags]     run the REST API
//	wtfd gc [flags]        remove attachment files nothing refers to any more
//	wtfd tenant <command> create, list or change tenants
//	wtfd history purge     delete old history entries
//
// Run "wtfd <action> -h" for the flags of an action. See WTFD.md.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/radiohyperactivity/wtf/db"
	"github.com/radiohyperactivity/wtf/internal/config"
	"github.com/radiohyperactivity/wtf/internal/files"
	"github.com/radiohyperactivity/wtf/internal/schema"
	"github.com/radiohyperactivity/wtf/internal/serve"
	"github.com/radiohyperactivity/wtf/internal/tenant"
)

const (
	exitOK      = 0
	exitPending = 1 // --dry-run only: changes are pending
	exitUsage   = 2
	exitFailure = 3
)

const usage = `Usage: wtfd <action> [flags]

Actions:
  schema    create or upgrade the database schema and function grants
  serve     run the REST API
  gc        remove attachment files nothing refers to any more
  tenant    create, list or change tenants
  history   delete old history entries (purge)

Run "wtfd <action> -h" for the flags of an action.
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return exitUsage
	}
	switch args[0] {
	case "schema":
		return runSchema(args[1:], stderr)
	case "serve":
		return runServe(args[1:], stderr)
	case "gc":
		return runGC(args[1:], stderr)
	case "tenant":
		return runTenant(args[1:], stdout, stderr)
	case "history":
		return runHistory(args[1:], stdout, stderr)
	case "help", "-h", "-help", "--help":
		fmt.Fprint(stderr, usage)
		return exitOK
	default:
		fmt.Fprintf(stderr, "wtfd: unknown action %q\n\n%s", args[0], usage)
		return exitUsage
	}
}

func runSchema(args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("wtfd schema", flag.ContinueOnError)
	fs.SetOutput(stderr)
	database := config.RegisterDatabase(fs)
	dryRun := fs.Bool("dry-run", false, "report what would be done, change nothing (exit code 1 if changes are pending)")
	verbose := fs.Bool("verbose", false, "log every migration, script and grant as it is applied")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK
		}
		return exitUsage
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(stderr, "wtfd schema: unexpected argument %q\n", fs.Arg(0))
		return exitUsage
	}
	if err := database.Validate(); err != nil {
		fmt.Fprintf(stderr, "wtfd schema: %v\n", err)
		return exitUsage
	}

	level := slog.LevelInfo
	if *verbose {
		level = slog.LevelDebug
	}
	log := slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{Level: level})).With("action", "schema")

	connConfig, err := database.ConnConfig(database.DBAUser, os.Getenv(config.DBAPasswordEnv), "wtfd schema")
	if err != nil {
		log.Error("invalid connection settings", "error", err)
		return exitUsage
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	result, err := schema.Run(ctx, schema.Options{
		ConnConfig: connConfig,
		APIUser:    database.APIUser,
		Scripts:    db.Scripts,
		DryRun:     *dryRun,
		Logger:     log,
	})
	if err != nil {
		log.Error("failed", "error", err)
		return exitFailure
	}
	if *dryRun && result.Pending {
		return exitPending
	}
	return exitOK
}

func runServe(args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("wtfd serve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	database := config.RegisterDatabase(fs)
	settings := config.RegisterServe(fs)
	filesDir := config.RegisterFiles(fs)
	verbose := fs.Bool("verbose", false, "debug logging")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK
		}
		return exitUsage
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(stderr, "wtfd serve: unexpected argument %q\n", fs.Arg(0))
		return exitUsage
	}
	if err := errors.Join(database.Validate(), settings.Validate(), filesDir.Validate()); err != nil {
		fmt.Fprintf(stderr, "wtfd serve: %v\n", err)
		return exitUsage
	}

	level := slog.LevelInfo
	if *verbose {
		level = slog.LevelDebug
	}
	log := slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{Level: level})).With("action", "serve")

	store, err := files.Open(filesDir.Directory)
	if err != nil {
		log.Error("failed", "error", err)
		return exitFailure
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	err = serve.Run(ctx, serve.Options{
		ConnString:         database.ConnString(database.APIUser, os.Getenv(config.APIPasswordEnv), "wtfd serve"),
		MaxConnections:     settings.MaxConnections,
		Listen:             settings.Listen,
		MaxRequestBodySize: settings.MaxRequestBodySize,
		Files:              store,
		MaxAttachmentSize:  settings.MaxAttachmentSize,
		Scripts:            db.Scripts,
		WebRoot:            settings.WebRoot,
		Logger:             log,
	})
	if err != nil {
		log.Error("failed", "error", err)
		return exitFailure
	}
	return exitOK
}

func runGC(args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("wtfd gc", flag.ContinueOnError)
	fs.SetOutput(stderr)
	database := config.RegisterDatabase(fs)
	filesDir := config.RegisterFiles(fs)
	settings := config.RegisterGC(fs)
	dryRun := fs.Bool("dry-run", false, "report what would be removed, remove nothing")
	verbose := fs.Bool("verbose", false, "log every removed file")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK
		}
		return exitUsage
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(stderr, "wtfd gc: unexpected argument %q\n", fs.Arg(0))
		return exitUsage
	}
	if err := errors.Join(database.Validate(), filesDir.Validate(), settings.Validate()); err != nil {
		fmt.Fprintf(stderr, "wtfd gc: %v\n", err)
		return exitUsage
	}

	level := slog.LevelInfo
	if *verbose {
		level = slog.LevelDebug
	}
	log := slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{Level: level})).With("action", "gc")

	connConfig, err := database.ConnConfig(database.DBAUser, os.Getenv(config.DBAPasswordEnv), "wtfd gc")
	if err != nil {
		log.Error("invalid connection settings", "error", err)
		return exitUsage
	}
	store, err := files.Open(filesDir.Directory)
	if err != nil {
		log.Error("failed", "error", err)
		return exitFailure
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	result, err := files.GC(ctx, files.GCOptions{
		ConnConfig: connConfig,
		Store:      store,
		MinAge:     settings.MinAge,
		DryRun:     *dryRun,
		Logger:     log,
	})
	if err != nil {
		log.Error("failed", "error", err)
		return exitFailure
	}
	verb := "removed"
	if *dryRun {
		verb = "would remove"
	}
	log.Info(verb, "files", result.Files, "bytes", result.Bytes)
	return exitOK
}

const tenantUsage = `Usage:
  wtfd tenant create --name NAME --hostname HOST --email EMAIL [database flags]
  wtfd tenant list [database flags]
  wtfd tenant update --name NAME [--new-name NAME] [--hostname HOST] [database flags]

Run "wtfd tenant <command> -h" for all flags.
`

func runTenant(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, tenantUsage)
		return exitUsage
	}
	command := args[0]
	fs := flag.NewFlagSet("wtfd tenant "+command, flag.ContinueOnError)
	fs.SetOutput(stderr)
	database := config.RegisterDatabase(fs)
	var name, hostname, email, newName *string
	switch command {
	case "create":
		name = fs.String("name", "", "tenant name (required)")
		hostname = fs.String("hostname", "", "hostname the tenant is reached at (required)")
		email = fs.String("email", "", "email of the first account, which gets every privilege (required)")
	case "list":
	case "update":
		name = fs.String("name", "", "current tenant name (required)")
		newName = fs.String("new-name", "", "new tenant name")
		hostname = fs.String("hostname", "", "new hostname")
	case "help", "-h", "-help", "--help":
		fmt.Fprint(stderr, tenantUsage)
		return exitOK
	default:
		fmt.Fprintf(stderr, "wtfd tenant: unknown command %q\n\n%s", command, tenantUsage)
		return exitUsage
	}
	if err := fs.Parse(args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK
		}
		return exitUsage
	}
	missing := func(flags ...string) bool {
		for _, f := range flags {
			if fs.Lookup(f).Value.String() == "" {
				fmt.Fprintf(stderr, "wtfd tenant %s: --%s is required\n", command, f)
				return true
			}
		}
		return false
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(stderr, "wtfd tenant %s: unexpected argument %q\n", command, fs.Arg(0))
		return exitUsage
	}
	if (command == "create" && missing("name", "hostname", "email")) || (command == "update" && missing("name")) {
		return exitUsage
	}
	if err := database.Validate(); err != nil {
		fmt.Fprintf(stderr, "wtfd tenant: %v\n", err)
		return exitUsage
	}

	connConfig, err := database.ConnConfig(database.DBAUser, os.Getenv(config.DBAPasswordEnv), "wtfd tenant")
	if err != nil {
		fmt.Fprintf(stderr, "wtfd tenant: %v\n", err)
		return exitUsage
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	conn, err := tenant.Connect(ctx, connConfig)
	if err != nil {
		fmt.Fprintf(stderr, "wtfd tenant: %v\n", err)
		return exitFailure
	}
	defer conn.Close(context.Background())

	switch command {
	case "create":
		password, err := tenant.Create(ctx, conn, *name, *hostname, *email)
		if err != nil {
			fmt.Fprintf(stderr, "wtfd tenant create: %v\n", err)
			return exitFailure
		}
		fmt.Fprintf(stdout, "Tenant %q created at %s.\n", *name, *hostname)
		fmt.Fprintf(stdout, "First account: %s\nPassword:      %s\n", *email, password)
		fmt.Fprintln(stdout, "The password is shown only this once; change it after logging in (PUT /me/password).")
	case "list":
		tenants, err := tenant.List(ctx, conn)
		if err != nil {
			fmt.Fprintf(stderr, "wtfd tenant list: %v\n", err)
			return exitFailure
		}
		for _, t := range tenants {
			fmt.Fprintf(stdout, "%-24s %-32s %d account(s)\n", t.Name, t.Hostname, t.Accounts)
		}
	case "update":
		if err := tenant.Update(ctx, conn, *name, *newName, *hostname); err != nil {
			fmt.Fprintf(stderr, "wtfd tenant update: %v\n", err)
			return exitFailure
		}
		fmt.Fprintln(stdout, "Tenant updated.")
	}
	return exitOK
}

const historyUsage = `Usage:
  wtfd history purge --older-than AGE [--tenant NAME] [--dry-run] [database flags]

AGE is a number of days (730d) or a Go duration (36h).
`

func runHistory(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] != "purge" {
		if len(args) > 0 && (args[0] == "help" || args[0] == "-h" || args[0] == "--help") {
			fmt.Fprint(stderr, historyUsage)
			return exitOK
		}
		fmt.Fprint(stderr, historyUsage)
		return exitUsage
	}
	fs := flag.NewFlagSet("wtfd history purge", flag.ContinueOnError)
	fs.SetOutput(stderr)
	database := config.RegisterDatabase(fs)
	olderThan := fs.String("older-than", "", "delete entries older than this, e.g. 730d (required)")
	tenantName := fs.String("tenant", "", "only this tenant (default: all tenants)")
	dryRun := fs.Bool("dry-run", false, "count the entries, delete nothing")
	if err := fs.Parse(args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK
		}
		return exitUsage
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(stderr, "wtfd history purge: unexpected argument %q\n", fs.Arg(0))
		return exitUsage
	}
	if *olderThan == "" {
		fmt.Fprintln(stderr, "wtfd history purge: --older-than is required")
		return exitUsage
	}
	age, err := tenant.ParseAge(*olderThan)
	if err != nil {
		fmt.Fprintf(stderr, "wtfd history purge: --older-than: %v\n", err)
		return exitUsage
	}
	if err := database.Validate(); err != nil {
		fmt.Fprintf(stderr, "wtfd history purge: %v\n", err)
		return exitUsage
	}

	connConfig, err := database.ConnConfig(database.DBAUser, os.Getenv(config.DBAPasswordEnv), "wtfd history")
	if err != nil {
		fmt.Fprintf(stderr, "wtfd history purge: %v\n", err)
		return exitUsage
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	conn, err := tenant.Connect(ctx, connConfig)
	if err != nil {
		fmt.Fprintf(stderr, "wtfd history purge: %v\n", err)
		return exitFailure
	}
	defer conn.Close(context.Background())

	n, err := tenant.PurgeHistory(ctx, conn, age, *tenantName, *dryRun)
	if err != nil {
		fmt.Fprintf(stderr, "wtfd history purge: %v\n", err)
		return exitFailure
	}
	if *dryRun {
		fmt.Fprintf(stdout, "Would delete %d history entries.\n", n)
	} else {
		fmt.Fprintf(stdout, "Deleted %d history entries.\n", n)
	}
	return exitOK
}
