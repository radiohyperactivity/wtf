// Command wtfd is the WtF server. Its first argument is an action:
//
//	wtfd schema [flags]    create or upgrade the database schema
//	wtfd serve [flags]     run the REST API
//	wtfd gc [flags]        remove attachment files nothing refers to any more
//	wtfd account <command> create an account, or set a lost password
//	wtfd database create   make the database and its roles on a server
//	wtfd install [flags]   set WtF up on this machine (Windows)
//	wtfd service <command> run wtfd serve as a Windows service
//
// Run "wtfd <action> -h" for the flags of an action. See WTFD.md.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	iofs "io/fs"
	"log/slog"
	"os"
	"os/signal"
	"slices"
	"syscall"

	"github.com/radiohyperactivity/wtf/db"
	"github.com/radiohyperactivity/wtf/internal/admin"
	"github.com/radiohyperactivity/wtf/internal/config"
	"github.com/radiohyperactivity/wtf/internal/files"
	"github.com/radiohyperactivity/wtf/internal/schema"
	"github.com/radiohyperactivity/wtf/internal/serve"
	"github.com/radiohyperactivity/wtf/internal/webapp"
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
  gc        remove files nothing refers to any more
  account   create an account, or set a lost password
  database  make the database and its roles on a server (create)
  install   set WtF up on this machine: programs, data, database (Windows)
  service   run wtfd serve as a Windows service (install, uninstall)

Run "wtfd <action> -h" for the flags of an action.
`

func main() {
	if code, ok := runService(os.Args[1:]); ok {
		os.Exit(code)
	}
	os.Exit(run(context.Background(), os.Args[1:], os.Stdout, os.Stderr))
}

// run runs an action. Cancelling ctx stops "serve" as SIGTERM does; the
// Windows service uses it for Stop and Shutdown.
func run(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return exitUsage
	}
	switch args[0] {
	case "schema":
		return runSchema(args[1:], stderr)
	case "serve":
		return runServe(ctx, args[1:], stderr)
	case "gc":
		return runGC(args[1:], stderr)
	case "account":
		return runAccount(args[1:], stdout, stderr)
	case "database":
		return runDatabase(args[1:], os.Stdin, stdout, stderr)
	case "install":
		return runInstall(args[1:], os.Stdin, stdout, stderr)
	case "service":
		return runServiceCommand(args[1:], os.Stdin, stdout, stderr)
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
	file := config.RegisterFile(fs)
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
	if !applyConfig(file, fs, stderr) {
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

func runServe(ctx context.Context, args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("wtfd serve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	database := config.RegisterDatabase(fs)
	file := config.RegisterFile(fs)
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
	if !applyConfig(file, fs, stderr) {
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
	if file.Read {
		log.Info("settings", "config", file.Path)
	}

	store, err := files.Open(filesDir.Directory)
	if err != nil {
		log.Error("failed", "error", err)
		return exitFailure
	}

	trusted, err := serve.ParseTrustedProxies(settings.TrustedProxies)
	if err != nil {
		log.Error("failed", "error", fmt.Errorf("--trusted-proxies: %w", err))
		return exitFailure
	}

	// The web app: from --web-root when given, else the one built in, if
	// any.
	var web iofs.FS
	switch {
	case settings.WebRoot != "":
		web = os.DirFS(settings.WebRoot)
		log.Info("web app", "from", settings.WebRoot)
	case webapp.Files != nil:
		web = webapp.Files
		log.Info("web app", "from", "built in")
	default:
		log.Info("web app", "from", "none: this wtfd has none built in, and --web-root isn't given")
	}

	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()

	err = serve.Run(ctx, serve.Options{
		ConnString:         database.ConnString(database.APIUser, os.Getenv(config.APIPasswordEnv), "wtfd serve"),
		MaxConnections:     settings.MaxConnections,
		Listen:             settings.Listen,
		MaxRequestBodySize: settings.MaxRequestBodySize,
		Files:              store,
		MaxAttachmentSize:  settings.MaxAttachmentSize,
		Scripts:            db.Scripts,
		Web:                web,
		TrustedProxies:     trusted,
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
	file := config.RegisterFile(fs)
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
	if !applyConfig(file, fs, stderr) {
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
	log.Info(verb, "files", result.Files, "bytes", result.Bytes, "expired_sessions", result.Sessions)
	return exitOK
}

const accountUsage = `Usage:
  wtfd account create --email EMAIL [--role ROLE] [database flags]
  wtfd account password --email EMAIL [database flags]

create makes an account, such as the first, an admin unless --role says
viewer or user; password gives an account a new password, when it is lost. Both print a
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
	file := config.RegisterFile(fs)
	email := fs.String("email", "", "the account's email (required)")
	role := "admin"
	if command == "create" {
		fs.StringVar(&role, "role", "admin", "the account's role: viewer, user or admin")
	}
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
	if !slices.Contains(admin.Roles, role) {
		fmt.Fprintf(stderr, "wtfd account %s: role %q: use viewer, user or admin\n", command, role)
		return exitUsage
	}
	if !applyConfig(file, fs, stderr) {
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
		password, err = admin.CreateAccount(ctx, conn, *email, role)
	} else {
		password, err = admin.SetPassword(ctx, conn, *email)
	}
	if err != nil {
		fmt.Fprintf(stderr, "wtfd account %s: %v\n", command, err)
		return exitFailure
	}
	if command == "create" {
		fmt.Fprintf(stdout, "Account %s created, %s %s.\n", *email, map[bool]string{true: "an", false: "a"}[role == "admin"], role)
	} else {
		fmt.Fprintf(stdout, "New password for %s; its sessions have ended.\n", *email)
	}
	fmt.Fprintf(stdout, "Password: %s\n", password)
	fmt.Fprintln(stdout, "The password is shown only this once; change it after logging in (PUT /me/password).")
	return exitOK
}
