package prompt

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"unicode/utf8"

	"golang.org/x/term"
)

// ErrInterrupted is returned when the user presses Ctrl-C.
var ErrInterrupted = errors.New("interrupted")

// Completer returns the candidates for the text typed so far. The editor
// filters them: by prefix for Tab, by substring in the picker.
type Completer func(input string) []string

// Terminal reads keys from a terminal and draws on it.
type Terminal struct {
	keys *keyReader
	out  io.Writer
	size func() (width, height int)
	raw  func() (restore func(), err error)
}

// New returns a Terminal on any reader and writer, 80×24, without raw mode.
// Tests use it.
func New(in io.Reader, out io.Writer) *Terminal {
	return &Terminal{
		keys: &keyReader{r: in},
		out:  out,
		size: func() (int, int) { return 80, 24 },
		raw:  func() (func(), error) { return func() {}, nil },
	}
}

// Open returns a Terminal reading from in and drawing on out, or nil when
// either is not a terminal.
func Open(in, out *os.File) *Terminal {
	if !IsTerminal(in) || !IsTerminal(out) {
		return nil
	}
	EnableVT(out)
	return &Terminal{
		keys: &keyReader{r: in},
		out:  out,
		size: func() (int, int) {
			w, h, err := term.GetSize(int(out.Fd()))
			if err != nil || w <= 0 || h <= 0 {
				return 80, 24
			}
			return w, h
		},
		raw: func() (func(), error) {
			state, err := term.MakeRaw(int(in.Fd()))
			if err != nil {
				return nil, err
			}
			return func() { _ = term.Restore(int(in.Fd()), state) }, nil
		},
	}
}

// IsTerminal reports whether f is a terminal.
func IsTerminal(f *os.File) bool { return f != nil && term.IsTerminal(int(f.Fd())) }

// Size returns the terminal's width and height.
func (t *Terminal) Size() (int, int) { return t.size() }

// ReadKey reads one key in raw mode.
func (t *Terminal) ReadKey() (Key, error) {
	restore, err := t.raw()
	if err != nil {
		return Key{}, err
	}
	defer restore()
	return t.keys.readKey()
}

// ReadLine reads a line after prompt, starting with initial. Tab completes
// from complete (which may be nil); a second Tab opens the picker. Ctrl-C
// returns ErrInterrupted and Ctrl-D on an empty line io.EOF.
func (t *Terminal) ReadLine(prompt, initial string, complete Completer) (string, error) {
	restore, err := t.raw()
	if err != nil {
		return "", err
	}
	defer restore()

	buf, pos := []rune(initial), utf8.RuneCountInString(initial)
	tabs := 0
	redraw := func() {
		var b strings.Builder
		b.WriteString("\r" + prompt + string(buf) + "\033[K")
		if back := len(buf) - pos; back > 0 {
			fmt.Fprintf(&b, "\033[%dD", back)
		}
		io.WriteString(t.out, b.String())
	}
	redraw()
	for {
		k, err := t.keys.readKey()
		if err != nil {
			return "", err
		}
		if k.Code != Tab {
			tabs = 0
		}
		switch k.Code {
		case Rune:
			buf = append(buf[:pos], append([]rune{k.Rune}, buf[pos:]...)...)
			pos++
		case Enter:
			io.WriteString(t.out, "\r\n")
			return string(buf), nil
		case Interrupt:
			io.WriteString(t.out, "^C\r\n")
			return "", ErrInterrupted
		case EOF:
			if len(buf) == 0 {
				io.WriteString(t.out, "\r\n")
				return "", io.EOF
			}
			fallthrough
		case Delete:
			if pos < len(buf) {
				buf = append(buf[:pos], buf[pos+1:]...)
			}
		case Backspace:
			if pos > 0 {
				buf = append(buf[:pos-1], buf[pos:]...)
				pos--
			}
		case Left:
			if pos > 0 {
				pos--
			}
		case Right:
			if pos < len(buf) {
				pos++
			}
		case Home:
			pos = 0
		case End:
			pos = len(buf)
		case KillEnd:
			buf = buf[:pos]
		case KillStart:
			buf, pos = buf[pos:], 0
		case KillWord:
			start := pos
			for start > 0 && buf[start-1] == ' ' {
				start--
			}
			for start > 0 && buf[start-1] != ' ' {
				start--
			}
			buf, pos = append(buf[:start], buf[pos:]...), start
		case Tab:
			if complete == nil {
				continue
			}
			tabs++
			if tabs >= 2 {
				tabs = 0
				choice, ok, err := t.pick(string(buf), complete)
				if err != nil {
					return "", err
				}
				if ok {
					buf = []rune(choice)
					pos = len(buf)
				}
				break
			}
			all := complete(string(buf))
			cands := MatchPrefix(all, string(buf))
			if len(cands) == 0 {
				// A single candidate containing the text will do ("scr" →
				// "Hardware/Screws").
				if sub := MatchSubstring(all, string(buf)); len(sub) == 1 {
					cands = sub
				}
			}
			switch len(cands) {
			case 0:
				io.WriteString(t.out, "\a")
			case 1:
				buf, tabs = []rune(cands[0]), 0
			default:
				if p := []rune(commonPrefix(cands)); len(p) >= len(buf) {
					buf = p
				}
			}
			pos = len(buf)
		}
		redraw()
	}
}

// Choose asks a question and lets the user pick one of items in the picker.
// It returns the index of the chosen item, or ErrInterrupted when the user
// cancels with Esc or Ctrl-C.
func (t *Terminal) Choose(question string, items []string) (int, error) {
	restore, err := t.raw()
	if err != nil {
		return -1, err
	}
	defer restore()
	io.WriteString(t.out, "\r"+question+"\033[K")
	choice, ok, err := t.pick("", func(string) []string { return items })
	if err != nil {
		return -1, err
	}
	if !ok {
		io.WriteString(t.out, "\r"+question+"^C\033[K\r\n")
		return -1, ErrInterrupted
	}
	io.WriteString(t.out, "\r"+question+choice+"\033[K\r\n")
	for i, item := range items {
		if item == choice {
			return i, nil
		}
	}
	return -1, ErrInterrupted
}

// pick shows the candidates matching filter below the prompt line and lets
// the user choose one: typing filters, arrows move, Enter picks, Esc cancels.
func (t *Terminal) pick(filter string, complete Completer) (string, bool, error) {
	width, height := t.size()
	rows := min(10, height-3)
	if rows < 1 {
		rows = 1
	}
	var items []string
	sel, top := 0, 0
	refresh := func() {
		items = MatchSubstring(complete(filter), filter)
		sel, top = 0, 0
	}
	draw := func() {
		var b strings.Builder
		b.WriteString("\r\033[J> " + filter)
		fmt.Fprintf(&b, "   \033[2m(%d)\033[0m", len(items))
		n := 0
		for i := top; i < len(items) && i < top+rows; i++ {
			line := truncate(items[i], width-3)
			if i == sel {
				b.WriteString("\r\n\033[7m " + line + " \033[0m")
			} else {
				b.WriteString("\r\n  " + line)
			}
			n++
		}
		if n > 0 {
			fmt.Fprintf(&b, "\033[%dA", n)
		}
		b.WriteString("\r")
		if c := 2 + utf8.RuneCountInString(filter); c > 0 {
			fmt.Fprintf(&b, "\033[%dC", c)
		}
		io.WriteString(t.out, b.String())
	}
	closePicker := func() { io.WriteString(t.out, "\r\033[J\033[A") }

	io.WriteString(t.out, "\r\n")
	refresh()
	for {
		draw()
		k, err := t.keys.readKey()
		if err != nil {
			closePicker()
			return "", false, err
		}
		switch k.Code {
		case Rune:
			filter += string(k.Rune)
			refresh()
		case Backspace:
			if r := []rune(filter); len(r) > 0 {
				filter = string(r[:len(r)-1])
				refresh()
			}
		case KillStart:
			filter = ""
			refresh()
		case Up:
			sel = max(sel-1, 0)
		case Down, Tab:
			sel = min(sel+1, max(len(items)-1, 0))
		case PageUp:
			sel = max(sel-rows, 0)
		case PageDown:
			sel = min(sel+rows, max(len(items)-1, 0))
		case Home:
			sel = 0
		case End:
			sel = max(len(items)-1, 0)
		case Enter:
			if len(items) == 0 {
				continue
			}
			closePicker()
			return items[sel], true, nil
		case Escape, Interrupt:
			closePicker()
			return "", false, nil
		}
		if sel < top {
			top = sel
		}
		if sel >= top+rows {
			top = sel - rows + 1
		}
	}
}

func truncate(s string, width int) string {
	r := []rune(s)
	if width < 2 || len(r) <= width {
		return s
	}
	return string(r[:width-1]) + "…"
}

// MatchPrefix returns the candidates that start with s, ignoring case.
func MatchPrefix(cands []string, s string) []string {
	var out []string
	for _, c := range cands {
		if len(c) >= len(s) && strings.EqualFold(c[:len(s)], s) {
			out = append(out, c)
		}
	}
	return out
}

// MatchSubstring returns the candidates that contain s, ignoring case.
func MatchSubstring(cands []string, s string) []string {
	s = strings.ToLower(s)
	var out []string
	for _, c := range cands {
		if strings.Contains(strings.ToLower(c), s) {
			out = append(out, c)
		}
	}
	return out
}

// commonPrefix is the longest prefix all candidates share, ignoring case,
// spelled as in the first candidate.
func commonPrefix(cands []string) string {
	p := []rune(cands[0])
	for _, c := range cands[1:] {
		r := []rune(c)
		n := 0
		for n < len(p) && n < len(r) && strings.EqualFold(string(p[n]), string(r[n])) {
			n++
		}
		p = p[:n]
	}
	return string(p)
}
