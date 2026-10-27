package cli

import (
	"flag"
	"math/big"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/radiohyperactivity/wtf/internal/client"
)

func TestNormalizeCode(t *testing.T) {
	for in, want := range map[string]string{
		"1a7k":     "1A7K",
		"1a-7k":    "1A7K",
		"IL0O":     "1100",
		"abc":      "", // too short
		"1A7U":     "", // U is not a Crockford digit
		"Garage 2": "", // space
		"Tool":     "T001",
	} {
		if got := normalizeCode(in); got != want {
			t.Errorf("normalizeCode(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSplitMeasure(t *testing.T) {
	for _, c := range []struct{ in, num, unit string }{
		{"12mm", "12", "mm"},
		{"2.5 m", "5/2", "m"},
		{"-3 °C", "-3", "°C"},
		{"1e3", "1000", ""},
		{".5kΩ", "1/2", "kΩ"},
	} {
		r, u, err := splitMeasure(c.in)
		if err != nil {
			t.Errorf("%q: %v", c.in, err)
			continue
		}
		if r.RatString() != c.num || u != c.unit {
			t.Errorf("%q = %s %q, want %s %q", c.in, r.RatString(), u, c.num, c.unit)
		}
	}
	if _, _, err := splitMeasure("mm"); err == nil {
		t.Error("expected an error for a missing number")
	}
}

func TestRatNumber(t *testing.T) {
	for in, want := range map[string]string{
		"12":        "12",
		"0.0012":    "0.0012",
		"1/3":       "0.333333333333333333333333333333",
		"25315/100": "253.15",
	} {
		r, ok := new(big.Rat).SetString(in)
		if !ok {
			t.Fatal(in)
		}
		if got := ratNumber(r).String(); got != want {
			t.Errorf("ratNumber(%s) = %s, want %s", in, got, want)
		}
	}
}

func TestMatchUnit(t *testing.T) {
	units := []unit{
		{Symbol: "Ω", Name: "ohm", BaseFactor: "1"},
		{Symbol: "mΩ", Name: "milliohm", BaseFactor: "0.001"},
		{Symbol: "kΩ", Name: "kiloohm", BaseFactor: "1000"},
		{Symbol: "MΩ", Name: "megaohm", BaseFactor: "1000000"},
		{Symbol: "µm", Name: "micrometre", BaseFactor: "0.000001"},
		{Symbol: "°C", Name: "degree Celsius", BaseFactor: "1", BaseOffset: "273.15"},
		{Symbol: "B", Name: "byte", BaseFactor: "1"}, // decimal bytes
		{Symbol: "B", Name: "byte", BaseFactor: "1"}, // binary bytes
	}
	for in, want := range map[string]string{
		"kΩ":             "kΩ",
		"kohm":           "kΩ",
		"MOhm":           "MΩ",
		"mohm":           "mΩ", // exact alias before case folding
		"um":             "µm",
		"μm":             "µm", // Greek mu
		"degC":           "°C",
		"degree celsius": "°C",
		"KILOOHM":        "kΩ",
		"MOHM":           "MΩ", // the alias keeps the case of the prefix
		"byte":           "B",  // two units, but they convert the same
	} {
		u, err := matchUnit(units, in)
		if err != nil {
			t.Errorf("%q: %v", in, err)
			continue
		}
		if u.Symbol != want {
			t.Errorf("%q matched %s, want %s", in, u.Symbol, want)
		}
	}
	if _, err := matchUnit(units, "mω"); err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Errorf("mω: want an ambiguity error, got %v", err)
	}
	if _, err := matchUnit(units, "ft"); err == nil {
		t.Error("ft: want an error")
	}
}

func TestTreeFind(t *testing.T) {
	str := func(s string) *string { return &s }
	ix := newTreeIndex(tree{Tree: []*node{
		{ID: "g", Name: "Garage", Children: []*node{
			{ID: "g1", Name: "Shelf 1", Parent: str("g")},
			{ID: "g2", Name: "Shelf 2", Parent: str("g")},
		}},
		{ID: "h", Name: "House", Children: []*node{
			{ID: "hg", Name: "Garage", Parent: str("h"), Children: []*node{
				{ID: "hg2", Name: "Shelf 2", Parent: str("hg")},
			}},
		}},
	}})
	ids := func(nodes []*node) []string {
		var out []string
		for _, n := range nodes {
			out = append(out, n.ID)
		}
		return out
	}
	for ref, want := range map[string][]string{
		"shelf 1":              {"g1"},
		"Garage/Shelf 2":       {"g2", "hg2"}, // no root rule: ambiguous
		"House/Garage/Shelf 2": {"hg2"},
		"House/Garage":         {"hg"},
		"Garage/Shelf 2/":      {"g2", "hg2"}, // a trailing "/" is ignored
		"/Garage":              nil,           // paths don't start with "/"
		"Nowhere":              nil,
	} {
		got := ids(ix.find(ref))
		slices.Sort(got)
		if !reflect.DeepEqual(got, want) {
			t.Errorf("find(%q) = %v, want %v", ref, got, want)
		}
	}
	if got := ix.pathString("hg2"); got != "House/Garage/Shelf 2" {
		t.Errorf("pathString = %q", got)
	}

	// The ambiguity error suggests the shortest unique path for each match,
	// or its code or id when no path is unique.
	ix.byID["g2"].Code = "1A7K"
	_, err := resolveTreeNode(ix, "location", "Shelf 2")
	if err == nil {
		t.Fatal("Shelf 2: want an ambiguity error")
	}
	for _, want := range []string{
		`location "Shelf 2" is ambiguous`,
		"1A7K                   for Garage/Shelf 2",
		"House/Garage/Shelf 2   for House/Garage/Shelf 2",
	} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error lacks %q:\n%v", want, err)
		}
	}
	if _, err := resolveTreeNode(ix, "location", "/Garage"); err == nil || !strings.Contains(err.Error(), `paths don't start with "/"`) {
		t.Errorf("/Garage: %v", err)
	}
}

func TestParseInterspersed(t *testing.T) {
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	name := fs.String("name", "", "")
	json := fs.Bool("json", false, "")
	got, err := parseInterspersed(fs, []string{"Drill", "--json", "Temp", "-5", "°C", "--name", "-3", "--", "--x"})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"Drill", "Temp", "-5", "°C", "--x"}
	if !reflect.DeepEqual(got, want) || *name != "-3" || !*json {
		t.Errorf("got %q name=%q json=%v", got, *name, *json)
	}
}

func TestConfigRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sub", "config.json")
	getenv := func(k string) string {
		if k == "WTF_CONFIG" {
			return path
		}
		return ""
	}
	c, err := loadConfig(getenv)
	if err != nil {
		t.Fatal(err)
	}
	c.Current = "dev"
	c.Profiles["dev"] = &Profile{Server: "http://localhost:8080", Email: "a@example.com", Token: "secret"}
	if err := c.save(); err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o600 {
			t.Errorf("mode = %v, %v", fi.Mode(), err)
		}
	}
	again, err := loadConfig(getenv)
	if err != nil {
		t.Fatal(err)
	}
	if again.Current != "dev" || *again.Profiles["dev"] != *c.Profiles["dev"] {
		t.Errorf("round trip lost data: %+v", again)
	}
}

func TestParsePrivilege(t *testing.T) {
	for in, want := range map[string]string{"read": "read_only", "RW": "read_write", "none": "none"} {
		if got, err := parsePrivilege(in); err != nil || got != want {
			t.Errorf("%q = %q, %v", in, got, err)
		}
	}
	if _, err := parsePrivilege("admin"); err == nil {
		t.Error("admin: want an error")
	}
}

func TestParseDate(t *testing.T) {
	now := time.Date(2026, 1, 31, 15, 4, 5, 0, time.Local)
	for in, want := range map[string]string{
		"today":      "2026-01-31",
		"Yesterday":  "2026-01-30",
		"tomorrow":   "2026-02-01",
		"+3":         "2026-02-03",
		"-3d":        "2026-01-28",
		"+2w":        "2026-02-14",
		"+1m":        "2026-02-28", // the end of February, not March 3
		"-2m":        "2025-11-30",
		"+1y":        "2027-01-31",
		"2024-02-29": "2024-02-29",
	} {
		if got, err := parseDate(in, now); err != nil || got != want {
			t.Errorf("parseDate(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"2024-02-30", "+3x", "soon", "3"} {
		if _, err := parseDate(bad, now); err == nil {
			t.Errorf("parseDate(%q): want an error", bad)
		}
	}
}

func TestSplitShellLine(t *testing.T) {
	for _, c := range []struct {
		line  string
		words []string
		raw   string
		quote byte
	}{
		{"wtf item get ", []string{"wtf", "item", "get", ""}, "", 0},
		{`wtf location get Garage/Shelf\ 2`, []string{"wtf", "location", "get", "Garage/Shelf 2"}, `Garage/Shelf\ 2`, 0},
		{`wtf location get "Garage/Sh`, []string{"wtf", "location", "get", "Garage/Sh"}, `"Garage/Sh`, '"'},
		{`wtf item get 'it''s`, []string{"wtf", "item", "get", "its"}, `'it''s`, '\''}, // the second quote is still open
		{`wtf x "a\"b" c`, []string{"wtf", "x", `a"b`, "c"}, "c", 0},
	} {
		words, raw, quote := splitShellLine(c.line)
		if !reflect.DeepEqual(words, c.words) || raw != c.raw || quote != c.quote {
			t.Errorf("%q: got %q %q %q", c.line, words, raw, quote)
		}
	}
}

func TestBashReplacement(t *testing.T) {
	for _, c := range []struct {
		cand, raw, bashCur string
		quote              byte
		want               string
	}{
		{"Garage", "gar", "gar", 0, "Garage "},
		{"Garage/Shelf 2", "Garage/Sh", "Garage/Sh", 0, `Garage/Shelf\ 2 `},
		{"Garage/", "Gar", "Gar", 0, "Garage/"},
		{"Garage/Shelf 2", `"Garage/Sh`, `"Garage/Sh`, '"', `"Garage/Shelf 2" `},
		// bash split "Colour=re" at "=": only "re" is replaced.
		{"Colour=red", "Colour=re", "re", 0, "red "},
		{"Colour=", "Col", "Col", 0, "Colour="},
	} {
		if got := bashReplacement(c.cand, c.raw, c.bashCur, c.quote); got != c.want {
			t.Errorf("%q for %q: got %q, want %q", c.cand, c.raw, got, c.want)
		}
	}
}

func TestTreeCandidates(t *testing.T) {
	str := func(s string) *string { return &s }
	ix := newTreeIndex(tree{Tree: []*node{
		{ID: "g", Name: "Garage", Children: []*node{
			{ID: "g1", Name: "Shelf 1", Parent: str("g")},
			{ID: "g2", Name: "Shelf 2", Parent: str("g"), Children: []*node{
				{ID: "b", Name: "Box", Parent: str("g2")},
			}},
		}},
		{ID: "a", Name: "Attic"},
	}})
	for cur, want := range map[string][]string{
		"":          {"Garage", "Garage/", "Attic"},
		"garage/":   {"garage/Shelf 1", "garage/Shelf 2", "garage/Shelf 2/"},
		"Garage/S":  {"Garage/Shelf 1", "Garage/Shelf 2", "Garage/Shelf 2/"},
		"Nowhere/x": nil,
	} {
		if got := treeCandidates(ix, cur, false, false); !reflect.DeepEqual(got, want) {
			t.Errorf("%q: got %q, want %q", cur, got, want)
		}
	}
	full := treeCandidates(ix, "", true, false)
	if !reflect.DeepEqual(full, []string{"Attic", "Garage", "Garage/Shelf 1", "Garage/Shelf 2", "Garage/Shelf 2/Box"}) {
		t.Errorf("full: %q", full)
	}

	// For "add", every node can be a parent, also one without children yet.
	parents := parentPaths(func(_ *env, _ []string, cur string, full bool) []string {
		return treeCandidates(ix, cur, full, false)
	})
	for cur, want := range map[string][]string{
		"":        {"Garage/", "Attic/"},
		"Garage/": {"Garage/Shelf 1/", "Garage/Shelf 2/"},
	} {
		if got := parents(nil, nil, cur, false); !reflect.DeepEqual(got, want) {
			t.Errorf("parents of %q: got %q, want %q", cur, got, want)
		}
	}
}

// TestCandidates covers completion that needs no server.
func TestCandidates(t *testing.T) {
	e := &env{api: client.New("", "")}
	for _, c := range []struct {
		words []string
		want  string // one expected candidate
		files bool
	}{
		{[]string{"it"}, "item", false},
		{[]string{"item", ""}, "value-set", false},
		{[]string{"item", "add", "X", "--"}, "--class", false},
		{[]string{"--json", "stock", "m"}, "move", false},
		{[]string{"attribute", "add", "Size", "--type", ""}, "choice", false},
		{[]string{"attribute", "add", "Size", "--type=f"}, "--type=float", false},
		{[]string{"account", "add", "a@b", "--data", ""}, "write", false},
		{[]string{"completion", ""}, "powershell", false},
		{[]string{"attachment", "add", "item", "Drill", ""}, "", true},
		{[]string{"attachment", "download", "x", "-o", ""}, "", true},
	} {
		got, files := e.candidates(c.words, false)
		if files != c.files {
			t.Errorf("%q: files = %v", c.words, files)
		}
		if c.want != "" && !slices.Contains(got, c.want) {
			t.Errorf("%q: %q lacks %q", c.words, got, c.want)
		}
	}
}

// TestPowerShellScript checks the script's command pattern, which must
// match wtf called by path with either slash ("./wtf", ".\wtf.exe").
func TestPowerShellScript(t *testing.T) {
	if !strings.Contains(powershellScript, `-match '(^|[\\/])wtf(\.exe)?$'`) {
		t.Error("the PowerShell script's wtf pattern is wrong")
	}
	if strings.Contains(powershellScript, "BACKTICK") {
		t.Error("the PowerShell script still contains the BACKTICK placeholder")
	}
}

// TestClassAmbiguity: a root class AVR and AVR under MCU. Classes have no
// codes, so the root one, which no path names uniquely, is offered by id.
func TestClassAmbiguity(t *testing.T) {
	str := func(s string) *string { return &s }
	ix := newTreeIndex(tree{Tree: []*node{
		{ID: "mcu", Name: "MCU", Children: []*node{
			{ID: "avr", Name: "AVR", Parent: str("mcu")},
		}},
		{ID: "root-avr", Name: "AVR"},
	}})
	_, err := resolveTreeNode(ix, "class", "avr")
	if err == nil {
		t.Fatal("want an ambiguity error")
	}
	for _, want := range []string{"root-avr   for AVR", "MCU/AVR    for MCU/AVR"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error lacks %q:\n%v", want, err)
		}
	}
	if id, err := resolveTreeNode(ix, "class", "MCU/AVR"); err != nil || id != "avr" {
		t.Errorf("MCU/AVR = %q, %v", id, err)
	}
}

func TestGrid(t *testing.T) {
	for n, want := range map[int]string{1: "A", 8: "H", 26: "Z", 27: "AA", 28: "AB", 52: "AZ", 53: "BA", 702: "ZZ", 703: "AAA"} {
		if got := columnLabel(n); got != want {
			t.Errorf("columnLabel(%d) = %q, want %q", n, got, want)
		}
	}
	if c, r, err := parseGrid("8x5"); err != nil || c != 8 || r != 5 {
		t.Errorf("8x5 = %d, %d, %v", c, r, err)
	}
	if c, r, err := parseGrid(" 3 X 12 "); err != nil || c != 3 || r != 12 {
		t.Errorf("3 X 12 = %d, %d, %v", c, r, err)
	}
	for _, bad := range []string{"8", "0x5", "8x0", "A1:H5", "-1x2", "99999999999x2"} {
		if _, _, err := parseGrid(bad); err == nil {
			t.Errorf("%q: want an error", bad)
		}
	}
}
