// Command wtfd is the WtF server. Its first argument is an action:
//
//	wtfd schema [flags]    create or upgrade the database schema
//	wtfd serve [flags]     run the REST API
//	wtfd gc [flags]        remove attachment files nothing refers to any more
//	wtfd account <command> create an account, or set a lost password
//	wtfd history purge     delete old history entries
//	wtfd deleted purge     remove what was deleted long ago
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
	"github.com/radiohyperactivity/wtf/internal/admin"
	"github.com/radiohyperactivity/wtf/internal/config"
	"github.com/radiohyperactivity/wtf/internal/files"
	"github.com/radiohyperactivity/wtf/internal/schema"
	"github.com/radiohyperactivity/wtf/internal/serve"
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
  account   create an account, or set a lost password
  history   delete old history entries (purge)
  deleted   remove what was deleted long ago (purge)

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
	case "account":
		return runAccount(args[1:], stdout, stderr)
	case "deleted":
		return runDeleted(args[1:], stdout, stderr)
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

const accountUsage = `Usage:
  wtfd account create --email EMAIL [database flags]
  wtfd account password --email EMAIL [database flags]

create makes an account with every privilege, such as the first one;
password gives an account a new password, when it is lost. Both print a
generated password once.
`

func runAccount(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, accountUsage)
		return exitUsage
	}
	command := args[0]
	switch command {
	case "create", "password":
	case "help", "-h", "-help", "--help":
		fmt.Fprint(stderr, accountUsage)
		return exitOK
	default:
		fmt.Fprintf(stderr, "wtfd account: unknown command %q\n\n%s", command, accountUsage)
		return exitUsage
	}
	fs := flag.NewFlagSet("wtfd account "+command, flag.ContinueOnError)
	fs.SetOutput(stderr)
	database := config.RegisterDatabase(fs)
	email := fs.String("email", "", "the account's email (required)")
	if err := fs.Parse(args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK
		}
		return exitUsage
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(stderr, "wtfd account %s: unexpected argument %q\n", command, fs.Arg(0))
		return exitUsage
	}
	if *email == "" {
		fmt.Fprintf(stderr, "wtfd account %s: --email is required\n", command)
		return exitUsage
	}
	if err := database.Validate(); err != nil {
		fmt.Fprintf(stderr, "wtfd account: %v\n", err)
		return exitUsage
	}

	connConfig, err := database.ConnConfig(database.DBAUser, os.Getenv(config.DBAPasswordEnv), "wtfd account")
	if err != nil {
		fmt.Fprintf(stderr, "wtfd account: %v\n", err)
		return exitUsage
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	conn, err := admin.Connect(ctx, connConfig)
	if err != nil {
		fmt.Fprintf(stderr, "wtfd account: %v\n", err)
		return exitFailure
	}
	defer conn.Close(context.Background())

	var password string
	if command == "create" {
		password, err = admin.CreateAccount(ctx, conn, *email)
	} else {
		password, err = admin.SetPassword(ctx, conn, *email)
	}
	if err != nil {
		fmt.Fprintf(stderr, "wtfd account %s: %v\n", command, err)
		return exitFailure
	}
	if command == "create" {
		fmt.Fprintf(stdout, "Account %s created, with every privilege.\n", *email)
	} else {
		fmt.Fprintf(stdout, "New password for %s; its sessions have ended.\n", *email)
	}
	fmt.Fprintf(stdout, "Password: %s\n", password)
	fmt.Fprintln(stdout, "The password is shown only this once; change it after logging in (PUT /me/password).")
	return exitOK
}

const historyUsage = `Usage:
  wtfd history purge --older-than AGE [--dry-run] [database flags]

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
	age, err := admin.ParseAge(*olderThan)
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
	conn, err := admin.Connect(ctx, connConfig)
	if err != nil {
		fmt.Fprintf(stderr, "wtfd history purge: %v\n", err)
		return exitFailure
	}
	defer conn.Close(context.Background())

	n, err := admin.PurgeHistory(ctx, conn, age, *dryRun)
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

const deletedUsage = `Usage:
  wtfd deleted purge --older-than AGE [--dry-run] [database flags]

Removes for good what was deleted longer ago than AGE: a number of days
(730d) or a Go duration (36h).
`

func runDeleted(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] != "purge" {
		fmt.Fprint(stderr, deletedUsage)
		if len(args) > 0 && (args[0] == "help" || args[0] == "-h" || args[0] == "--help") {
			return exitOK
		}
		return exitUsage
	}
	fs := flag.NewFlagSet("wtfd deleted purge", flag.ContinueOnError)
	fs.SetOutput(stderr)
	database := config.RegisterDatabase(fs)
	olderThan := fs.String("older-than", "", "remove what was deleted longer ago than this, e.g. 730d (required)")
	dryRun := fs.Bool("dry-run", false, "count what would be removed, remove nothing")
	if err := fs.Parse(args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK
		}
		return exitUsage
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(stderr, "wtfd deleted purge: unexpected argument %q\n", fs.Arg(0))
		return exitUsage
	}
	if *olderThan == "" {
		fmt.Fprintln(stderr, "wtfd deleted purge: --older-than is required")
		return exitUsage
	}
	age, err := admin.ParseAge(*olderThan)
	if err != nil {
		fmt.Fprintf(stderr, "wtfd deleted purge: --older-than: %v\n", err)
		return exitUsage
	}
	if err := database.Validate(); err != nil {
		fmt.Fprintf(stderr, "wtfd deleted purge: %v\n", err)
		return exitUsage
	}

	connConfig, err := database.ConnConfig(database.DBAUser, os.Getenv(config.DBAPasswordEnv), "wtfd deleted")
	if err != nil {
		fmt.Fprintf(stderr, "wtfd deleted purge: %v\n", err)
		return exitUsage
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	conn, err := admin.Connect(ctx, connConfig)
	if err != nil {
		fmt.Fprintf(stderr, "wtfd deleted purge: %v\n", err)
		return exitFailure
	}
	defer conn.Close(context.Background())

	counts, err := admin.PurgeDeleted(ctx, conn, age, *dryRun)
	if err != nil {
		fmt.Fprintf(stderr, "wtfd deleted purge: %v\n", err)
		return exitFailure
	}
	verb := "Removed"
	if *dryRun {
		verb = "Would remove"
	}
	for _, kind := range admin.PurgedKinds {
		fmt.Fprintf(stdout, "%s %d %s.\n", verb, counts[kind.Table], kind.Name)
	}
	return exitOK
}
