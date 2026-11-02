package cli

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/url"
	"strconv"
	"unicode/utf8"

	"github.com/radiohyperactivity/wtf/internal/prompt"
)

// Paged lists, paged by key (the API's after and next). One page is shown,
// with a note when more follow; with --all, every row is: on a terminal
// through a pager that fetches pages only as they are needed, else all at
// once.

// paging is --limit and --all.
type paging struct {
	limit int
	all   bool
}

func (p *paging) register(fs *flag.FlagSet) {
	fs.IntVar(&p.limit, "limit", 100, "rows on a page (1–1000)")
	fs.BoolVar(&p.all, "all", false, "show every row, not only the first page")
}

// listing is a paged API list and how to show it.
type listing struct {
	path  string
	query url.Values
	batch int // rows per request in the pager (default 100)
	// empty is printed to stderr instead when there are no rows.
	empty string
	// render formats one page of rows; header is true for the first page.
	render func(data json.RawMessage, header bool) ([]string, error)
}

func (e *env) fetchPage(l listing, limit int, after string) (json.RawMessage, page[json.RawMessage], error) {
	q := url.Values{}
	for k, v := range l.query {
		q[k] = v
	}
	q.Set("limit", strconv.Itoa(limit))
	if after != "" {
		q.Set("after", after)
	}
	var pg page[json.RawMessage]
	data, err := e.api.Get(e.ctx, l.path, q)
	if err == nil {
		err = e.decode(data, &pg)
	}
	return data, pg, err
}

func (e *env) list(p paging, l listing) error {
	if !p.all {
		data, pg, err := e.fetchPage(l, p.limit, "")
		if err != nil {
			return err
		}
		if e.json {
			return e.printJSON(data)
		}
		if len(pg.Rows) == 0 && l.empty != "" {
			fmt.Fprintln(e.stderr, l.empty)
			return nil
		}
		lines, err := l.render(data, true)
		if err != nil {
			return err
		}
		for _, line := range lines {
			fmt.Fprintln(e.stdout, line)
		}
		e.pageFooter(pg.More)
		return nil
	}

	if e.json {
		// One answer with every row.
		all := page[json.RawMessage]{Rows: []json.RawMessage{}}
		for after := ""; ; {
			_, pg, err := e.fetchPage(l, 1000, after)
			if err != nil {
				return err
			}
			all.Rows = append(all.Rows, pg.Rows...)
			if !pg.More {
				break
			}
			after = pg.Next
		}
		data, err := json.Marshal(all)
		if err != nil {
			return err
		}
		return e.printJSON(data)
	}

	pg := e.pager()
	size := 1000
	if pg != nil {
		size = l.batch
		if size == 0 {
			size = 100
		}
	}
	for after, first := "", true; ; first = false {
		data, page, err := e.fetchPage(l, size, after)
		if err != nil {
			return err
		}
		if first && len(page.Rows) == 0 && l.empty != "" {
			fmt.Fprintln(e.stderr, l.empty)
			return nil
		}
		lines, err := l.render(data, first)
		if err != nil {
			return err
		}
		for _, line := range lines {
			if pg == nil {
				fmt.Fprintln(e.stdout, line)
			} else if !pg.line(line) {
				return nil
			}
		}
		if !page.More {
			return nil
		}
		after = page.Next
	}
}

// pager shows lines a screen at a time, like more.
type pager struct {
	t             *prompt.Terminal
	w             io.Writer
	width, height int
	used          int // screen lines used since the last pause
}

// pager returns a pager when stdin and stdout are a terminal, else nil.
func (e *env) pager() *pager {
	t := OpenTerminal(e.stdin, e.stdout)
	if t == nil {
		return nil
	}
	w, h := t.Size()
	return &pager{t: t, w: e.stdout, width: max(w, 1), height: max(h, 3)}
}

// line prints a line, pausing first when the screen is full. It returns
// false when the user quits.
func (p *pager) line(s string) bool {
	if p.used >= p.height-1 && !p.more() {
		return false
	}
	fmt.Fprintln(p.w, s)
	p.used += max(1, (utf8.RuneCountInString(s)+p.width-1)/p.width)
	return true
}

// more asks how to go on: Space a screen, Enter a line, q quits.
func (p *pager) more() bool {
	for {
		fmt.Fprint(p.w, "\033[7m-- More --  Space: next page  Enter: next line  q: quit\033[0m")
		k, err := p.t.ReadKey()
		fmt.Fprint(p.w, "\r\033[K")
		if err != nil {
			return false
		}
		switch {
		case k.Code == prompt.Rune && k.Rune == ' ', k.Code == prompt.PageDown:
			p.used = 0
			return true
		case k.Code == prompt.Enter, k.Code == prompt.Down:
			p.used = p.height - 2
			return true
		case k.Code == prompt.Rune && (k.Rune == 'q' || k.Rune == 'Q'),
			k.Code == prompt.Escape, k.Code == prompt.Interrupt, k.Code == prompt.EOF:
			return false
		}
	}
}
