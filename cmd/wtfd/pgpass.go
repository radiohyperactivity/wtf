package main

import (
	"strconv"
	"strings"
)

// pgpassLine is a line of PostgreSQL's password file:
// hostname:port:database:username:password.
func pgpassLine(host string, port int, database, user, password string) string {
	return strings.Join([]string{
		pgpassField(host), strconv.Itoa(port), pgpassField(database), pgpassField(user), pgpassField(password),
	}, ":")
}

// pgpassField escapes a field of a line in PostgreSQL's password file.
func pgpassField(s string) string {
	return strings.NewReplacer(`\`, `\\`, `:`, `\:`).Replace(s)
}

// mergePgpass puts lines into the password file's text old: a line for the
// same host, port, database and user replaces the old one in its place,
// other lines are added at the end, and the rest stays as it was.
func mergePgpass(old string, lines []string) string {
	key := func(line string) string {
		// The password is what follows the fourth unescaped colon.
		colons := 0
		for i := 0; i < len(line); i++ {
			switch line[i] {
			case '\\':
				i++
			case ':':
				if colons++; colons == 4 {
					return line[:i]
				}
			}
		}
		return ""
	}
	pending := map[string]string{}
	var order []string
	for _, l := range lines {
		k := key(l)
		if _, ok := pending[k]; !ok {
			order = append(order, k)
		}
		pending[k] = l
	}

	var out []string
	if old = strings.TrimRight(old, "\r\n"); old != "" {
		for l := range strings.SplitSeq(old, "\n") {
			l = strings.TrimRight(l, "\r")
			if k := key(l); k != "" && !strings.HasPrefix(l, "#") {
				if nl, ok := pending[k]; ok {
					l = nl
					delete(pending, k)
				}
			}
			out = append(out, l)
		}
	}
	for _, k := range order {
		if l, ok := pending[k]; ok {
			out = append(out, l)
		}
	}
	return strings.Join(out, "\n") + "\n"
}
