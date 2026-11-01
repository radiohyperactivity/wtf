package cli

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/term"

	"github.com/radiohyperactivity/wtf/internal/client"
)

// readLine prompts on stderr and reads one line from stdin.
func (e *env) readLine(prompt string) (string, error) {
	if e.term != nil {
		e.prompted = true
		return e.term.ReadLine(prompt, "", nil)
	}
	fmt.Fprint(e.stderr, prompt)
	if e.lines == nil {
		e.lines = bufio.NewReader(e.stdin)
	}
	line, err := e.lines.ReadString('\n')
	if err != nil && line == "" {
		return "", fmt.Errorf("no input for %q", strings.TrimSpace(prompt))
	}
	return strings.TrimRight(line, "\r\n"), nil
}

// readPassword prompts without echo on a terminal; otherwise it reads a line
// from stdin, so passwords can be piped in.
func (e *env) readPassword(prompt string) (string, error) {
	if f, ok := e.stdin.(*os.File); ok && term.IsTerminal(int(f.Fd())) {
		fmt.Fprint(e.stderr, prompt)
		b, err := term.ReadPassword(int(f.Fd()))
		fmt.Fprintln(e.stderr)
		return string(b), err
	}
	return e.readLine(prompt)
}

// newPassword asks for a new password twice.
func (e *env) newPassword(prompt string) (string, error) {
	p, err := e.readPassword(prompt)
	if err != nil {
		return "", err
	}
	if f, ok := e.stdin.(*os.File); ok && term.IsTerminal(int(f.Fd())) {
		again, err := e.readPassword("Repeat: ")
		if err != nil {
			return "", err
		}
		if again != p {
			return "", errors.New("the passwords differ")
		}
	}
	return p, nil
}

func loginCommand() command {
	return command{
		name:    "login",
		args:    "[--server URL] [--email EMAIL] [--profile NAME] [--stay DURATION|forever]",
		summary: "Log in. Password: prompted, or WTF_PASSWORD.",
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			email := fs.String("email", "", "account email (default: the profile's)")
			stay := fs.String("stay", "", "how long the session lasts unused, e.g. 30d or 12h, or forever (default: the last one given, or forever)")
			return func(e *env, args []string) error {
				if err := wantArgs(args, 0, 0); err != nil {
					return err
				}
				if *stay == "" {
					*stay = e.config.Stay
				}
				maxIdle, err := parseStay(*stay)
				if err != nil {
					return usagef("--stay: %v", err)
				}
				p := e.config.Profiles[e.profile]
				if p == nil {
					p = &Profile{}
				}
				server := e.api.Server
				if server == "" {
					return usagef("no server: give --server URL, e.g. --server http://localhost:8080")
				}
				if *email == "" {
					*email = p.Email
				}
				if *email == "" {
					var err error
					if *email, err = e.readLine("Email: "); err != nil {
						return err
					}
				}
				password := e.getenv("WTF_PASSWORD")
				if password == "" {
					var err error
					if password, err = e.readPassword("Password: "); err != nil {
						return err
					}
				}

				anonymous := client.New(server, "")
				body := object{"email": *email, "password": password, "client": clientName(), "max_idle": maxIdle}
				data, header, err := anonymous.Do(e.ctx, http.MethodPost, "/login", nil, body)
				if err != nil {
					return err
				}
				var result struct {
					Account account `json:"account"`
				}
				if err := e.decode(data, &result); err != nil {
					return err
				}
				// The session comes as a cookie; the CLI keeps it in the profile
				// and sends it back as one.
				token := client.SessionFrom(header)
				if token == "" {
					return errors.New("the server's login answer has no session cookie")
				}
				p.Server, p.Email, p.Token = strings.TrimRight(server, "/"), result.Account.Email, token
				e.config.Profiles[e.profile] = p
				e.config.Current = e.profile
				if *stay != "" {
					e.config.Stay = *stay
				}
				if err := e.config.save(); err != nil {
					return err
				}
				return e.emit(data, func() error {
					fmt.Fprintf(e.stdout, "Logged in to %s as %s (profile %q).\n", p.Server, result.Account.Email, e.profile)
					return nil
				})
			}
		},
	}
}

func logoutCommand() command {
	return command{
		name:    "logout",
		summary: "End the session and remove the token from the profile.",
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			return func(e *env, args []string) error {
				if err := wantArgs(args, 0, 0); err != nil {
					return err
				}
				_, _, err := e.api.Do(e.ctx, http.MethodPost, "/logout", nil, nil)
				var p *client.Problem
				if errors.As(err, &p) && p.Status == http.StatusUnauthorized {
					err = nil // the session had ended already
				}
				if err != nil {
					return err
				}
				if prof := e.config.Profiles[e.profile]; prof != nil && prof.Token != "" {
					prof.Token = ""
					if err := e.config.save(); err != nil {
						return err
					}
				}
				if !e.json {
					fmt.Fprintln(e.stdout, "Logged out.")
				}
				return nil
			}
		},
	}
}

func whoamiCommand() command {
	return command{
		name:    "whoami",
		summary: "Show the logged-in account and its role.",
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			return func(e *env, args []string) error {
				if err := wantArgs(args, 0, 0); err != nil {
					return err
				}
				data, err := e.api.Get(e.ctx, "/me", nil)
				if err != nil {
					return err
				}
				return e.emit(data, func() error {
					var a account
					if err := e.decode(data, &a); err != nil {
						return err
					}
					fields(e.stdout,
						"Email", a.Email,
						"Server", e.api.Server,
						"Profile", e.profile,
						"Role", a.Role)
					return nil
				})
			}
		},
	}
}

func passwordCommand() command {
	return command{
		name:    "password",
		args:    "[--log-out-others | --keep-others]",
		summary: "Change your password, and log out your other sessions or keep them (asked when no flag says).",
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			logOut := fs.Bool("log-out-others", false, "end your other sessions")
			keep := fs.Bool("keep-others", false, "keep your other sessions")
			return func(e *env, args []string) error {
				if err := wantArgs(args, 0, 0); err != nil {
					return err
				}
				if *logOut && *keep {
					return usagef("give --log-out-others or --keep-others, not both")
				}
				current, err := e.readPassword("Current password: ")
				if err != nil {
					return err
				}
				next, err := e.newPassword("New password: ")
				if err != nil {
					return err
				}
				end := *logOut
				if !*logOut && !*keep {
					if end, err = e.yesNo("Log out your other devices too?"); err != nil {
						return err
					}
				}
				body := object{"current": current, "new": next, "end_other_sessions": end}
				if _, _, err := e.api.Do(e.ctx, http.MethodPut, "/me/password", nil, body); err != nil {
					return err
				}
				if !e.json {
					fmt.Fprintln(e.stdout, "Password changed.")
				}
				return nil
			}
		},
	}
}

func profileGroup() group {
	return group{
		name:    "profile",
		summary: "Configuration profiles (servers and logins)",
		commands: []command{
			{
				name:    "list",
				summary: "List the profiles; * marks the current one.",
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					return func(e *env, args []string) error {
						if err := wantArgs(args, 0, 0); err != nil {
							return err
						}
						t := newTable(e.stdout, "", "PROFILE", "SERVER", "EMAIL", "LOGGED IN")
						for _, n := range e.config.profileNames() {
							p := e.config.Profiles[n]
							mark := ""
							if n == e.config.Current {
								mark = "*"
							}
							t.row(mark, n, p.Server, p.Email, yesNo(p.Token != ""))
						}
						t.flush()
						return nil
					}
				},
			},
			{
				name:    "use",
				args:    "<name>",
				summary: "Make a profile the current one.",
				params:  []param{arg("Profile", completeProfiles)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					return func(e *env, args []string) error {
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						if e.config.Profiles[args[0]] == nil {
							return fmt.Errorf("no profile %q; create it with 'wtf login --profile %s --server URL'", args[0], args[0])
						}
						e.config.Current = args[0]
						return e.config.save()
					}
				},
			},
			{
				name:    "delete",
				args:    "<name>",
				summary: "Remove a profile (it does not log out on the server).",
				params:  []param{arg("Profile", completeProfiles)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					return func(e *env, args []string) error {
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						if e.config.Profiles[args[0]] == nil {
							return fmt.Errorf("no profile %q", args[0])
						}
						delete(e.config.Profiles, args[0])
						if e.config.Current == args[0] {
							e.config.Current = ""
						}
						return e.config.save()
					}
				},
			},
		},
	}
}

// parseStay reads a session's lifetime for "wtf login --stay": "forever" (or
// nothing) for a session that lasts until logging out, or how long it may go
// unused, as a Go duration (12h) or in days (30d). It returns the seconds the
// API takes, or nil for forever.
func parseStay(s string) (any, error) {
	s = strings.TrimSpace(s)
	if s == "" || strings.EqualFold(s, "forever") {
		return nil, nil
	}
	var d time.Duration
	if days, ok := strings.CutSuffix(s, "d"); ok {
		n, err := strconv.Atoi(days)
		if err != nil {
			return nil, fmt.Errorf("%q is not a number of days", s)
		}
		d = time.Duration(n) * 24 * time.Hour
	} else {
		var err error
		if d, err = time.ParseDuration(s); err != nil {
			return nil, fmt.Errorf("%q is not a duration (like 30d or 12h) or forever", s)
		}
	}
	if d < time.Second {
		return nil, fmt.Errorf("%q is too short", s)
	}
	return int64(d / time.Second), nil
}

// clientName is what the CLI calls itself at login, so that the list of
// sessions says which device each is: "wtf on <host name>".
func clientName() string {
	if host, err := os.Hostname(); err == nil && host != "" {
		return "wtf on " + host
	}
	return "wtf"
}

// yesNo asks a yes or no question until it gets an answer.
func (e *env) yesNo(question string) (bool, error) {
	for {
		v, err := e.readLine(question + " [yes/no] ")
		if err != nil {
			return false, err
		}
		if b, ok := parseYesNo(v); ok {
			return b, nil
		}
		fmt.Fprintln(e.stderr, "Answer yes or no.")
	}
}

// sessionsGroup is the logged-in account's own sessions: its devices.
func sessionsGroup() group {
	return group{
		name:    "sessions",
		summary: "Your sessions (the devices you are logged in on)",
		commands: []command{
			{
				name:    "list",
				summary: "List your sessions, most recently used first; * marks this one.",
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					return func(e *env, args []string) error {
						if err := wantArgs(args, 0, 0); err != nil {
							return err
						}
						data, err := e.api.Get(e.ctx, "/me/sessions", nil)
						if err != nil {
							return err
						}
						return e.emit(data, func() error {
							var list []session
							if err := e.decode(data, &list); err != nil {
								return err
							}
							t := newTable(e.stdout, "", "ID", "CLIENT", "LAST USED", "FROM", "EXPIRES")
							for _, s := range list {
								mark := ""
								if s.Current {
									mark = "*"
								}
								client, from, expires := "", "", "when logged out"
								if s.Client != nil {
									client = *s.Client
								}
								if len(s.Usage) > 0 {
									from = s.Usage[0].Address
								}
								if s.Expires != nil {
									expires = localTime(*s.Expires)
								}
								t.row(mark, s.ID, client, localTime(s.LastUsed), from, expires)
							}
							t.flush()
							return nil
						})
					}
				},
			},
			{
				name:    "logout",
				args:    "<session id> | --others",
				summary: "End one of your sessions (this one logs out), or with --others all but this one.",
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					others := fs.Bool("others", false, "end all your sessions but this one")
					return func(e *env, args []string) error {
						if *others {
							if err := wantArgs(args, 0, 0); err != nil {
								return err
							}
							data, _, err := e.api.Do(e.ctx, http.MethodPost, "/me/sessions/logout-others", nil, nil)
							if err != nil {
								return err
							}
							return e.emit(data, func() error {
								var r struct {
									Ended int `json:"ended"`
								}
								if err := e.decode(data, &r); err != nil {
									return err
								}
								fmt.Fprintf(e.stdout, "Ended %s.\n", count(r.Ended, "other session", "other sessions"))
								return nil
							})
						}
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						if _, _, err := e.api.Do(e.ctx, http.MethodDelete, "/me/sessions/"+url.PathEscape(args[0]), nil, nil); err != nil {
							return err
						}
						if !e.json {
							fmt.Fprintln(e.stdout, "Session ended.")
						}
						return nil
					}
				},
			},
		},
	}
}
