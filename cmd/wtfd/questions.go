package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"golang.org/x/term"

	"github.com/radiohyperactivity/wtf/internal/admin"
)

var errCancelled = errors.New("cancelled")

// questions asks on a terminal. Each answer may be left empty to take the
// default shown in brackets.
type questions struct {
	in  *bufio.Reader
	fd  int
	out io.Writer
}

// openQuestions returns questions on stdin, or nil when it isn't a
// terminal, and nothing can be asked.
func openQuestions(stdin *os.File, stdout io.Writer) *questions {
	if !term.IsTerminal(int(stdin.Fd())) {
		return nil
	}
	return &questions{in: bufio.NewReader(stdin), fd: int(stdin.Fd()), out: stdout}
}

func (q *questions) text(question, def string) (string, error) {
	if def != "" {
		fmt.Fprintf(q.out, "%s [%s]: ", question, def)
	} else {
		fmt.Fprintf(q.out, "%s: ", question)
	}
	line, err := q.in.ReadString('\n')
	if err != nil {
		if errors.Is(err, io.EOF) {
			fmt.Fprintln(q.out)
			return "", errCancelled
		}
		return "", err
	}
	if line = strings.TrimSpace(line); line == "" {
		return def, nil
	}
	return line, nil
}

func (q *questions) number(question string, def int) (int, error) {
	for {
		s, err := q.text(question, strconv.Itoa(def))
		if err != nil {
			return 0, err
		}
		if n, err := strconv.Atoi(s); err == nil {
			return n, nil
		}
		fmt.Fprintln(q.out, "  That's not a number.")
	}
}

func (q *questions) yes(question string, def bool) (bool, error) {
	answer := map[bool]string{true: "yes", false: "no"}[def]
	for {
		s, err := q.text(question+" (yes/no)", answer)
		if err != nil {
			return false, err
		}
		switch strings.ToLower(s) {
		case "y", "yes":
			return true, nil
		case "n", "no":
			return false, nil
		}
		fmt.Fprintln(q.out, "  Yes or no?")
	}
}

// password reads a password without showing it.
func (q *questions) password(question string) (string, error) {
	fmt.Fprintf(q.out, "%s: ", question)
	b, err := term.ReadPassword(q.fd)
	fmt.Fprintln(q.out)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// newPassword asks for a role's new password, twice; empty generates one.
func (q *questions) newPassword(role string) (string, error) {
	for {
		p, err := q.password(fmt.Sprintf("  Password for %s (empty: generate one)", role))
		if err != nil || p == "" {
			return p, err
		}
		if err := admin.CheckPassword(p); err != nil {
			fmt.Fprintf(q.out, "  It %v.\n", err)
			continue
		}
		again, err := q.password("  Again")
		if err != nil {
			return "", err
		}
		if again == p {
			return p, nil
		}
		fmt.Fprintln(q.out, "  The two weren't the same; once more.")
	}
}
