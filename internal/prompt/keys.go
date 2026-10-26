// Package prompt reads keys and lines from a terminal in raw mode: a small
// line editor with tab completion, an interactive picker, and single keys
// for a pager. Output uses ANSI/VT escape sequences.
package prompt

import (
	"io"
	"unicode/utf8"
)

// Code is the kind of a key.
type Code int

const (
	Rune      Code = iota // a printable character, in Key.Rune
	Enter                 // Enter / Return
	Tab                   // Tab
	Backspace             // Backspace
	Delete                // Delete, or Ctrl-D on a non-empty line
	Left                  // ← or Ctrl-B
	Right                 // → or Ctrl-F
	Up                    // ↑ or Ctrl-P
	Down                  // ↓ or Ctrl-N
	Home                  // Home or Ctrl-A
	End                   // End or Ctrl-E
	PageUp                // Page Up
	PageDown              // Page Down
	Escape                // Esc
	Interrupt             // Ctrl-C
	EOF                   // Ctrl-D
	KillEnd               // Ctrl-K: delete to the end of the line
	KillStart             // Ctrl-U: delete to the start of the line
	KillWord              // Ctrl-W: delete the word before the cursor
	Unknown               // anything else
)

// Key is one key press.
type Key struct {
	Code Code
	Rune rune
}

// keyReader decodes key presses from raw terminal input. An escape sequence
// is expected to arrive in one read, which is how terminals send them; a
// lone ESC byte is the Esc key.
type keyReader struct {
	r   io.Reader
	buf []byte
}

func (k *keyReader) fill() error {
	var b [256]byte
	for {
		n, err := k.r.Read(b[:])
		k.buf = append(k.buf, b[:n]...)
		if n > 0 {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

var controls = map[byte]Code{
	0x01: Home, 0x02: Left, 0x03: Interrupt, 0x04: EOF, 0x05: End, 0x06: Right,
	0x08: Backspace, 0x09: Tab, 0x0b: KillEnd, 0x0e: Down, 0x10: Up,
	0x15: KillStart, 0x17: KillWord, 0x7f: Backspace,
}

// readKey returns the next key.
func (k *keyReader) readKey() (Key, error) {
	for len(k.buf) == 0 {
		if err := k.fill(); err != nil {
			return Key{}, err
		}
	}
	b := k.buf[0]
	switch {
	case b == 0x1b:
		if len(k.buf) > 1 && (k.buf[1] == '[' || k.buf[1] == 'O') {
			return k.sequence(), nil
		}
		k.buf = k.buf[1:]
		return Key{Code: Escape}, nil
	case b == '\r' || b == '\n':
		k.buf = k.buf[1:]
		if b == '\r' && len(k.buf) > 0 && k.buf[0] == '\n' {
			k.buf = k.buf[1:]
		}
		return Key{Code: Enter}, nil
	case b < 0x20 || b == 0x7f:
		k.buf = k.buf[1:]
		if c, ok := controls[b]; ok {
			return Key{Code: c}, nil
		}
		return Key{Code: Unknown}, nil
	}
	for !utf8.FullRune(k.buf) {
		if err := k.fill(); err != nil {
			return Key{}, err
		}
	}
	r, n := utf8.DecodeRune(k.buf)
	k.buf = k.buf[n:]
	return Key{Code: Rune, Rune: r}, nil
}

// sequence decodes "ESC [ params final" and "ESC O final".
func (k *keyReader) sequence() Key {
	i := 2
	for i < len(k.buf) && (k.buf[i] < 0x40 || k.buf[i] > 0x7e) {
		i++
	}
	if i >= len(k.buf) {
		k.buf = k.buf[:0]
		return Key{Code: Unknown}
	}
	final, params := k.buf[i], string(k.buf[2:i])
	k.buf = k.buf[i+1:]
	if j := indexByte(params, ';'); j >= 0 {
		params = params[:j] // ignore modifiers (Shift, Ctrl, …)
	}
	switch final {
	case 'A':
		return Key{Code: Up}
	case 'B':
		return Key{Code: Down}
	case 'C':
		return Key{Code: Right}
	case 'D':
		return Key{Code: Left}
	case 'H':
		return Key{Code: Home}
	case 'F':
		return Key{Code: End}
	case '~':
		switch params {
		case "1", "7":
			return Key{Code: Home}
		case "4", "8":
			return Key{Code: End}
		case "3":
			return Key{Code: Delete}
		case "5":
			return Key{Code: PageUp}
		case "6":
			return Key{Code: PageDown}
		}
	}
	return Key{Code: Unknown}
}

func indexByte(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}
