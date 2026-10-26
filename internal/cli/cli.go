// Package cli implements the wtf command-line client. See CLI.md.
package cli

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"text/tabwriter"

	"github.com/radiohyperactivity/wtf/internal/client"
	"github.com/radiohyperactivity/wtf/internal/prompt"
)

// command is one "wtf <noun> <verb>" (or top-level "wtf <verb>").
type command struct {
	name    string
	args    string // usage of the positional arguments
	summary string
	// setup defines the command's flags and returns the function that runs it.
	setup func(fs *flag.FlagSet) func(e *env, args []string) error
	// params describe the positional arguments, and flags the values of
	// flags (by name), for prompting and completion.
	params []param
	flags  map[string]param
}

// group is a noun with its verbs.
type group struct {
	name     string
	summary  string
	commands []command
}

// env is what a running command needs.
type env struct {
	ctx     context.Context
	stdin   io.Reader
	stdout  io.Writer
	stderr  io.Writer
	getenv  func(string) string
	config  *Config
	profile string // name of the profile in use
	json    bool   // --json: print the API's JSON
	server  string // --server override
	api     *client.Client
	cache   cache
	lines   *bufio.Reader // stdin, for prompts
	// term is the terminal for interactive prompts (stdin and stderr), or
	// nil when either is redirected.
	term       *prompt.Terminal
	prompted   bool // the user has been asked for something: ask for more
	completing bool // running for shell completion
}

// OpenTerminal returns the terminal on in and out, or nil. Tests replace it
// to drive prompts and the pager with scripted keys.
var OpenTerminal = func(in io.Reader, out io.Writer) *prompt.Terminal {
	f, ok1 := in.(*os.File)
	g, ok2 := out.(*os.File)
	if !ok1 || !ok2 {
		return nil
	}
	return prompt.Open(f, g)
}

// Run runs the client with the command-line arguments (without the program
// name) and returns the exit code: 0 success, 1 error, 2 usage.
func Run(ctx context.Context, args []string, stdin io.Reader, stdout, stderr io.Writer, getenv func(string) string) int {
	e := &env{ctx: ctx, stdin: stdin, stdout: stdout, stderr: stderr, getenv: getenv}

	// Global flags may also come before the command.
	args = e.takeGlobalFlags(args)
	if len(args) > 0 && args[0] == "__complete" {
		return e.complete(args[1:])
	}
	if len(args) == 0 || args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		if len(args) > 1 {
			return e.usage(args[1:])
		}
		printOverview(stdout)
		return 0
	}

	cmd, name, rest, ok := lookup(args)
	if !ok && name != "" {
		fmt.Fprintf(stderr, "wtf: %s has no verb %q\n\n", name, args[1])
		printGroup(stderr, name)
		return 2
	}
	if !ok {
		fmt.Fprintf(stderr, "wtf: unknown command %q\n\n", args[0])
		printOverview(stderr)
		return 2
	}
	if cmd == nil { // a noun without a verb
		printGroup(stdout, name)
		return 0
	}

	fs := flag.NewFlagSet("wtf "+name, flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.BoolVar(&e.json, "json", e.json, "print the API's JSON")
	fs.StringVar(&e.profile, "profile", e.profile, "configuration profile (env WTF_PROFILE)")
	fs.StringVar(&e.server, "server", e.server, "server URL, overriding the profile (env WTF_SERVER)")
	run := cmd.setup(fs)
	fs.Usage = func() {
		fmt.Fprintf(stderr, "Usage: wtf %s %s\n\n%s\n\nFlags:\n", name, cmd.args, cmd.summary)
		fs.PrintDefaults()
	}
	positional, err := parseInterspersed(fs, rest)
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}

	if err := e.init(); err != nil {
		fmt.Fprintf(stderr, "wtf: %v\n", err)
		return 1
	}
	e.term = OpenTerminal(stdin, stderr)
	err = e.askMissing(cmd, &positional)
	if err == nil {
		err = run(e, positional)
	}
	if warning := revisionWarning(e.api.ServerRevision, client.APIRevision); warning != "" {
		fmt.Fprintln(stderr, warning)
	}
	if errors.Is(err, prompt.ErrInterrupted) || (errors.Is(err, io.EOF) && e.prompted) {
		return 130
	}
	if err != nil {
		var u usageError
		if errors.As(err, &u) {
			fmt.Fprintf(stderr, "wtf %s: %v\nUsage: wtf %s %s\n", name, err, name, cmd.args)
			return 2
		}
		fmt.Fprintf(stderr, "wtf: %v\n", err)
		var p *client.Problem
		if errors.As(err, &p) && p.Status == 401 && name != "login" {
			fmt.Fprintln(stderr, "Log in with 'wtf login'.")
		}
		return 1
	}
	return 0
}

// usageError is a wrong number or kind of arguments.
type usageError struct{ msg string }

func (u usageError) Error() string { return u.msg }

func usagef(format string, a ...any) error { return usageError{fmt.Sprintf(format, a...)} }

// wantArgs checks the number of positional arguments.
func wantArgs(args []string, min, max int) error {
	switch {
	case len(args) < min:
		return usagef("missing arguments")
	case max >= 0 && len(args) > max:
		return usagef("too many arguments: %s", strings.Join(args[max:], " "))
	}
	return nil
}

// takeGlobalFlags consumes --json, --profile and --server before the command.
func (e *env) takeGlobalFlags(args []string) []string {
	for len(args) > 0 {
		a := args[0]
		switch {
		case a == "--json" || a == "-json":
			e.json = true
			args = args[1:]
		case (a == "--profile" || a == "-profile" || a == "--server" || a == "-server") && len(args) > 1:
			if strings.HasSuffix(a, "profile") {
				e.profile = args[1]
			} else {
				e.server = args[1]
			}
			args = args[2:]
		case strings.HasPrefix(a, "--profile="):
			e.profile = strings.TrimPrefix(a, "--profile=")
			args = args[1:]
		case strings.HasPrefix(a, "--server="):
			e.server = strings.TrimPrefix(a, "--server=")
			args = args[1:]
		default:
			return args
		}
	}
	return args
}

// init loads the configuration and sets up the API client.
func (e *env) init() error {
	cfg, err := loadConfig(e.getenv)
	if err != nil {
		return err
	}
	e.config = cfg
	if e.profile == "" {
		e.profile = e.getenv("WTF_PROFILE")
	}
	if e.profile == "" {
		e.profile = cfg.Current
	}
	if e.profile == "" {
		e.profile = "default"
	}
	p := cfg.Profiles[e.profile]
	if p == nil {
		p = &Profile{}
	}
	server, token := p.Server, p.Token
	if v := e.getenv("WTF_SERVER"); v != "" {
		server = v
	}
	if e.server != "" {
		server = e.server
	}
	if v := e.getenv("WTF_TOKEN"); v != "" {
		token = v
	}
	e.api = newClient(server, token)
	return nil
}

// Transport, when set, carries all requests; tests use it to reach an
// in-process server under the tenant's hostname.
var Transport http.RoundTripper

func newClient(server, token string) *client.Client {
	c := client.New(server, token)
	if Transport != nil {
		c.HTTP.Transport = Transport
	}
	return c
}

// parseInterspersed parses flags that may appear between positional
// arguments, and returns the positional arguments. "--" ends the flags.
// Negative numbers ("-5", "-3.5°C") are positional unless they are the value
// of a flag.
func parseInterspersed(fs *flag.FlagSet, args []string) ([]string, error) {
	var positional []string
	for {
		// Parse up to the next negative number that isn't a flag value.
		end := len(args)
		for i, a := range args {
			if a == "--" {
				break
			}
			if negativeNumber.MatchString(a) && (i == 0 || !takesValue(fs, args[i-1])) {
				end = i
				break
			}
		}
		if err := fs.Parse(args[:end]); err != nil {
			return nil, err
		}
		rest := append(fs.Args(), args[end:]...)
		if len(rest) == 0 {
			return positional, nil
		}
		if rest[0] == "--" {
			return append(positional, rest[1:]...), nil
		}
		positional = append(positional, rest[0])
		args = rest[1:]
	}
}

var negativeNumber = regexp.MustCompile(`^-(\d|\.\d)`)

// takesValue is true for a flag like "--name" whose value is the next argument.
func takesValue(fs *flag.FlagSet, arg string) bool {
	if !strings.HasPrefix(arg, "-") || strings.Contains(arg, "=") {
		return false
	}
	f := fs.Lookup(strings.TrimLeft(arg, "-"))
	if f == nil {
		return false
	}
	b, ok := f.Value.(interface{ IsBoolFlag() bool })
	return !ok || !b.IsBoolFlag()
}

// lookup finds the command for args: a top-level command, or noun + verb.
// It returns cmd == nil for a noun without (or with an unknown) verb.
func lookup(args []string) (*command, string, []string, bool) {
	for i := range topLevel {
		if topLevel[i].name == args[0] {
			return &topLevel[i], args[0], args[1:], true
		}
	}
	for _, g := range groups {
		if g.name != args[0] {
			continue
		}
		if len(args) < 2 || strings.HasPrefix(args[1], "-") {
			return nil, g.name, nil, true
		}
		for i := range g.commands {
			if g.commands[i].name == args[1] {
				return &g.commands[i], g.name + " " + args[1], args[2:], true
			}
		}
		return nil, g.name, nil, false // a noun with an unknown verb
	}
	return nil, "", nil, false
}

func (e *env) usage(args []string) int {
	cmd, name, _, ok := lookup(args)
	switch {
	case !ok:
		printOverview(e.stderr)
		return 2
	case cmd == nil:
		printGroup(e.stdout, name)
	default:
		fmt.Fprintf(e.stdout, "Usage: wtf %s %s\n\n%s\n\nRun 'wtf %s -h' for its flags.\n", name, cmd.args, cmd.summary, name)
	}
	return 0
}

func printOverview(w io.Writer) {
	fmt.Fprintln(w, "Usage: wtf <command> [arguments] [flags]")
	fmt.Fprintln(w, "\nCommands:")
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	for _, c := range topLevel {
		fmt.Fprintf(tw, "  %s %s\t%s\n", c.name, c.args, c.summary)
	}
	tw.Flush()
	fmt.Fprintln(w, "\nObjects (wtf <object> <verb>; 'wtf <object>' lists the verbs):")
	tw = tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	names := make([]string, 0, len(groups))
	summaries := map[string]string{}
	for _, g := range groups {
		names = append(names, g.name)
		summaries[g.name] = g.summary
	}
	sort.Strings(names)
	for _, n := range names {
		fmt.Fprintf(tw, "  %s\t%s\n", n, summaries[n])
	}
	tw.Flush()
	fmt.Fprintln(w, "\nObjects can be named by id, label code or name/path (e.g. 'Garage/Shelf 2').")
	fmt.Fprintln(w, "Global flags: --json (print the API's JSON), --profile NAME, --server URL.")
}

func printGroup(w io.Writer, name string) {
	for _, g := range groups {
		if g.name != name {
			continue
		}
		fmt.Fprintf(w, "wtf %s: %s\n\n", g.name, g.summary)
		tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
		for _, c := range g.commands {
			fmt.Fprintf(tw, "  wtf %s %s %s\t%s\n", g.name, c.name, c.args, c.summary)
		}
		tw.Flush()
	}
}

// Main is the entry point of cmd/wtf.
func Main() int {
	return Run(context.Background(), os.Args[1:], os.Stdin, os.Stdout, os.Stderr, os.Getenv)
}

// revisionWarning warns when the server's API revision (0: unknown) is older
// than the one this client was built for. Within API version 1 the server
// only ever adds, so an older revision may lack something the client uses.
func revisionWarning(server, built int) string {
	if server <= 0 || server >= built {
		return ""
	}
	return fmt.Sprintf("wtf: the server's API (revision %d) is older than this client's (revision %d); some commands may not work. Update the server (wtfd).", server, built)
}
