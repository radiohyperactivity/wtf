package cli

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strings"

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
		args:    "[--server URL] [--email EMAIL] [--profile NAME]",
		summary: "Log in. Password: prompted, or WTF_PASSWORD.",
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			email := fs.String("email", "", "account email (default: the profile's)")
			return func(e *env, args []string) error {
				if err := wantArgs(args, 0, 0); err != nil {
					return err
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
				data, header, err := anonymous.Do(e.ctx, http.MethodPost, "/login", nil, object{"email": *email, "password": password})
				if err != nil {
					return err
				}
				var result struct {
					Account account `json:"account"`
				}
				if err := decode(data, &result); err != nil {
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
		summary: "Show the logged-in account and its privileges.",
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
					if err := decode(data, &a); err != nil {
						return err
					}
					fields(e.stdout,
						"Email", a.Email,
						"Server", e.api.Server,
						"Profile", e.profile,
						"Privileges", privileges(a))
					return nil
				})
			}
		},
	}
}

func privileges(a account) string {
	return fmt.Sprintf("data %s, model %s, account %s, history %s",
		a.DataPrivilege, a.ModelPrivilege, a.AccountPrivilege, a.HistoryPrivilege)
}

func passwordCommand() command {
	return command{
		name:    "password",
		summary: "Change your password. Your other sessions end.",
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			return func(e *env, args []string) error {
				if err := wantArgs(args, 0, 0); err != nil {
					return err
				}
				current, err := e.readPassword("Current password: ")
				if err != nil {
					return err
				}
				next, err := e.newPassword("New password: ")
				if err != nil {
					return err
				}
				if _, _, err := e.api.Do(e.ctx, http.MethodPut, "/me/password", nil, object{"current": current, "new": next}); err != nil {
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
