package prompt

import (
	"bytes"
	"errors"
	"io"
	"testing"
)

// chunks returns one chunk per Read, as a terminal delivers key presses.
type chunks []string

func (c *chunks) Read(p []byte) (int, error) {
	if len(*c) == 0 {
		return 0, io.EOF
	}
	n := copy(p, (*c)[0])
	*c = (*c)[1:]
	return n, nil
}

func TestReadKey(t *testing.T) {
	in := chunks{"a", "é", "\x1b[A", "\x1b[3~", "\x1bOH", "\x1b", "\r\n", "\x7f", "\x03", "\x1b[1;5C"}
	k := &keyReader{r: &in}
	want := []Key{{Rune, 'a'}, {Rune, 'é'}, {Code: Up}, {Code: Delete}, {Code: Home}, {Code: Escape},
		{Code: Enter}, {Code: Backspace}, {Code: Interrupt}, {Code: Right}}
	for i, w := range want {
		got, err := k.readKey()
		if err != nil || got != w {
			t.Fatalf("key %d = %+v, %v; want %+v", i, got, err, w)
		}
	}
	if _, err := k.readKey(); err != io.EOF {
		t.Errorf("at the end: %v, want EOF", err)
	}
}

func places(string) []string { return []string{"Garage", "Garden", "Attic"} }

func readLine(t *testing.T, keys ...string) (string, error) {
	t.Helper()
	in := chunks(keys)
	var out bytes.Buffer
	return New(&in, &out).ReadLine("Location: ", "", places)
}

func TestReadLineEditing(t *testing.T) {
	got, err := readLine(t, "a", "b", "c", "\x1b[D", "\x1b[D", "X", "\x1b[F", "\x7f", "\r")
	if err != nil || got != "aXb" {
		t.Errorf("got %q, %v", got, err)
	}
	got, err = readLine(t, "one", " ", "two", "\x17", "\r")
	if err != nil || got != "one " {
		t.Errorf("Ctrl-W: got %q, %v", got, err)
	}
	if _, err = readLine(t, "x", "\x03"); !errors.Is(err, ErrInterrupted) {
		t.Errorf("Ctrl-C: %v", err)
	}
	if _, err = readLine(t, "\x04"); err != io.EOF {
		t.Errorf("Ctrl-D: %v", err)
	}
}

func TestReadLineTab(t *testing.T) {
	// "gar" extends to the common prefix "Gar"; "a" + Tab is unique.
	got, err := readLine(t, "g", "a", "r", "\t", "a", "\t", "\r")
	if err != nil || got != "Garage" {
		t.Errorf("got %q, %v", got, err)
	}
}

func TestChoose(t *testing.T) {
	items := []string{"MCU/STM8", "STM8"}
	choose := func(keys ...string) (int, string, error) {
		in := chunks(keys)
		var out bytes.Buffer
		i, err := New(&in, &out).Choose(`Which class "STM8"? `, items)
		return i, out.String(), err
	}
	if i, out, err := choose("\x1b[B", "\r"); err != nil || i != 1 || !bytes.Contains([]byte(out), []byte(`Which class "STM8"? STM8`)) {
		t.Errorf("down, enter: %d, %v\n%q", i, err, out)
	}
	if i, _, err := choose("m", "c", "u", "\r"); err != nil || i != 0 {
		t.Errorf("filter: %d, %v", i, err)
	}
	if _, _, err := choose("\x1b"); !errors.Is(err, ErrInterrupted) {
		t.Errorf("escape: %v", err)
	}
}

func TestPicker(t *testing.T) {
	// Double Tab opens the picker; typing filters by substring.
	got, err := readLine(t, "\t", "\t", "d", "e", "n", "\r", "\r")
	if err != nil || got != "Garden" {
		t.Errorf("filter: got %q, %v", got, err)
	}
	// Arrows move; the list keeps the completer's order.
	got, err = readLine(t, "\t", "\t", "\x1b[B", "\x1b[B", "\r", "\r")
	if err != nil || got != "Attic" {
		t.Errorf("arrows: got %q, %v", got, err)
	}
	// Esc cancels and keeps the typed text.
	got, err = readLine(t, "x", "\t", "\t", "\x1b", "\r")
	if err != nil || got != "x" {
		t.Errorf("escape: got %q, %v", got, err)
	}
}
