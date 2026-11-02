package cli

import (
	"encoding/json"
	"flag"
	"fmt"
	"math/big"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

// Attribute values on the command line (CLI.md, decision 70). An attribute
// is a flag of its own: --colour Blue sets "Colour", --no-colour removes
// it, and --default colour puts it back to the class's default. Letter case
// is ignored and a hyphen stands for a space, so --supply-voltage is
// "Supply voltage". An attribute named like one of the command's own flags
// is set with --value NAME=VALUE.

// attrFlag is a flag that is none of the command's own: an attribute's
// value, or with remove, its removal.
type attrFlag struct {
	name   string // as typed, without the dashes
	value  string
	remove bool
}

// takeAttributeFlags takes the flags that fs doesn't define out of args, as
// attribute values: "--colour Blue", "--colour=Blue" and "--no-colour". A
// flag's value is the next argument unless that is a flag itself (a
// negative number is a value). The rest is returned for fs to parse, with
// the values of fs's own flags. "--" ends the flags.
func takeAttributeFlags(fs *flag.FlagSet, args []string) ([]string, []attrFlag) {
	var rest []string
	var taken []attrFlag
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			return append(rest, args[i:]...), taken
		}
		if !strings.HasPrefix(a, "-") || a == "-" || negativeNumber.MatchString(a) {
			rest = append(rest, a)
			continue
		}
		name, value, hasValue := strings.Cut(strings.TrimLeft(a, "-"), "=")
		if fs.Lookup(name) != nil || name == "h" || name == "help" {
			rest = append(rest, a)
			if !hasValue && takesValue(fs, a) && i+1 < len(args) {
				rest = append(rest, args[i+1])
				i++
			}
			continue
		}
		if after, ok := strings.CutPrefix(name, "no-"); ok && !hasValue {
			taken = append(taken, attrFlag{name: after, remove: true})
			continue
		}
		if !hasValue && i+1 < len(args) && (!strings.HasPrefix(args[i+1], "-") || negativeNumber.MatchString(args[i+1])) {
			value = args[i+1]
			i++
		}
		taken = append(taken, attrFlag{name: name, value: value})
	}
	return rest, taken
}

// normalizeName is an attribute's or a flag's name as they are matched:
// in lower case, with hyphens and underscores as spaces, and single spaces.
func normalizeName(s string) string {
	s = strings.ToLower(strings.NewReplacer("-", " ", "_", " ").Replace(s))
	return strings.Join(strings.Fields(s), " ")
}

// matchAttribute finds the attribute of scope ("item" or "stock") that the
// flag or name ref names, among a class's attributes.
func matchAttribute(c class, scope, ref string) (attribute, error) {
	want := normalizeName(ref)
	var found []attribute
	for _, a := range c.Attributes {
		if a.Scope == scope && normalizeName(a.Name) == want {
			found = append(found, a)
		}
	}
	switch len(found) {
	case 1:
		return found[0], nil
	case 0:
		var names []string
		for _, a := range c.Attributes {
			if a.Scope == scope {
				names = append(names, a.Name)
			}
		}
		what := map[string]string{"item": "item", "stock": "stock"}[scope]
		if len(names) == 0 {
			return attribute{}, usagef("class %s has no %s attributes, so there is nothing called %q", c.Name, what, ref)
		}
		return attribute{}, usagef("class %s has no %s attribute %q; it has: %s", c.Name, what, ref, strings.Join(names, ", "))
	}
	var names []string
	for _, a := range found {
		names = append(names, fmt.Sprintf("%q", a.Name))
	}
	return attribute{}, usagef("%q could be %s; set it with --value NAME=VALUE", ref, strings.Join(names, " or "))
}

var numberPattern = regexp.MustCompile(`^\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)\s*(.*?)\s*$`)

// parseNumber reads a number, which may be followed by unit, the label of
// what it is counted in ("12 mm" when unit is "mm"); another label is
// refused, as nothing converts.
func parseNumber(input, unit string) (json.Number, error) {
	m := numberPattern.FindStringSubmatch(input)
	if m == nil {
		return "", fmt.Errorf("%q is not a number", input)
	}
	if m[2] != "" && !strings.EqualFold(m[2], unit) {
		if unit == "" {
			return "", fmt.Errorf("%q: a number without a unit is wanted", input)
		}
		return "", fmt.Errorf("%q: the number is in %s, and nothing converts", input, unit)
	}
	r, ok := new(big.Rat).SetString(m[1])
	if !ok {
		return "", fmt.Errorf("%q is not a number", input)
	}
	if r.IsInt() {
		return json.Number(r.Num().String()), nil
	}
	return json.Number(strings.TrimRight(strings.TrimRight(r.FloatString(20), "0"), ".")), nil
}

// parseValue reads input as a value of attribute a: a number (with its unit
// label, if it has one), a date (parseDate), yes or no, one of a choice's choices (letter case ignored), or
// text. A file is uploaded instead.
func parseValue(a attribute, input string) (any, error) {
	input = strings.TrimSpace(input)
	switch a.Type {
	case "integer", "decimal":
		n, err := parseNumber(input, a.Unit)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", a.Name, err)
		}
		if a.Type == "integer" && strings.ContainsAny(n.String(), ".eE") {
			return nil, fmt.Errorf("%s takes whole numbers, not %s", a.Name, n)
		}
		return n, nil
	case "date":
		d, err := parseDate(input, time.Now())
		if err != nil {
			return nil, fmt.Errorf("%s: %w", a.Name, err)
		}
		return d, nil
	case "boolean":
		b, ok := parseYesNo(input)
		if !ok {
			return nil, fmt.Errorf("%s takes yes or no, not %q", a.Name, input)
		}
		return b, nil
	case "choice":
		for _, c := range a.Choices {
			if strings.EqualFold(c, input) {
				return c, nil
			}
		}
		return nil, fmt.Errorf("%s is one of %s, not %q", a.Name, strings.Join(a.Choices, ", "), input)
	case "attachment":
		return nil, fmt.Errorf("%s is a file: upload it with 'wtf file put'", a.Name)
	}
	if input == "" {
		return nil, fmt.Errorf("%s can't be empty", a.Name)
	}
	return input, nil
}

// parseYesNo reads yes/no, true/false, y/n or 1/0.
func parseYesNo(input string) (bool, bool) {
	switch strings.ToLower(strings.TrimSpace(input)) {
	case "yes", "y", "true", "1", "on":
		return true, true
	case "no", "n", "false", "0", "off":
		return false, true
	}
	return false, false
}

var relativeDate = regexp.MustCompile(`^([+-]\d+)\s*([dwmy]?)$`)

// parseDate accepts YYYY-MM-DD, today, yesterday, tomorrow, and a date
// relative to today: +3 or +3d (days), -2w (weeks), +1m (months), -1y
// (years). A month or year step that lands past the end of a month stops at
// its last day (2026-01-31 +1m is 2026-02-28).
func parseDate(input string, now time.Time) (string, error) {
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	switch strings.ToLower(strings.TrimSpace(input)) {
	case "today":
		return today.Format(time.DateOnly), nil
	case "yesterday":
		return today.AddDate(0, 0, -1).Format(time.DateOnly), nil
	case "tomorrow":
		return today.AddDate(0, 0, 1).Format(time.DateOnly), nil
	}
	if m := relativeDate.FindStringSubmatch(strings.ToLower(strings.TrimSpace(input))); m != nil {
		n, err := strconv.Atoi(m[1])
		if err != nil {
			return "", fmt.Errorf("%q: %w", input, err)
		}
		var d time.Time
		switch m[2] {
		case "", "d":
			d = today.AddDate(0, 0, n)
		case "w":
			d = today.AddDate(0, 0, 7*n)
		case "m":
			d = addMonths(today, n)
		case "y":
			d = addMonths(today, 12*n)
		}
		return d.Format(time.DateOnly), nil
	}
	if _, err := time.Parse(time.DateOnly, strings.TrimSpace(input)); err != nil {
		return "", fmt.Errorf("%q is not a date (YYYY-MM-DD, today, yesterday, tomorrow, or +/-N[d|w|m|y])", input)
	}
	return strings.TrimSpace(input), nil
}

// addMonths adds n calendar months, keeping the day but not past the end of
// the target month.
func addMonths(t time.Time, n int) time.Time {
	first := time.Date(t.Year(), t.Month()+time.Month(n), 1, 0, 0, 0, 0, time.UTC)
	last := first.AddDate(0, 1, -1).Day()
	return first.AddDate(0, 0, min(t.Day(), last)-1)
}

// valueChanges turns the attribute flags (e.attrFlags), the --value
// NAME=VALUE flags and the --default flags into the values and default of
// a create or a patch of an item or stock row (scope) of class c: values
// {"<name>": <value>, or null to remove}, default ["<name>", ...].
func (e *env) valueChanges(c class, scope string, explicit, defaults []string) (object, []string, error) {
	set := object{}
	add := func(ref string, text string, remove bool) error {
		a, err := matchAttribute(c, scope, ref)
		if err != nil {
			return err
		}
		if _, twice := set[a.Name]; twice {
			return usagef("%s is given twice", a.Name)
		}
		if remove {
			set[a.Name] = nil
			return nil
		}
		v, err := parseValue(a, text)
		if err != nil {
			return err
		}
		set[a.Name] = v
		return nil
	}
	for _, f := range e.attrFlags {
		if err := add(f.name, f.value, f.remove); err != nil {
			return nil, nil, err
		}
	}
	for _, s := range explicit {
		name, text, ok := strings.Cut(s, "=")
		if !ok {
			return nil, nil, usagef("--value %q: expected NAME=VALUE", s)
		}
		if err := add(name, text, false); err != nil {
			return nil, nil, err
		}
	}
	var names []string
	for _, ref := range defaults {
		a, err := matchAttribute(c, scope, ref)
		if err != nil {
			return nil, nil, err
		}
		if !a.hasDefault() {
			return nil, nil, usagef("%s has no default", a.Name)
		}
		if _, both := set[a.Name]; both || slices.Contains(names, a.Name) {
			return nil, nil, usagef("%s is given twice", a.Name)
		}
		names = append(names, a.Name)
	}
	return set, names, nil
}

// conditionPattern splits "Resistance >= 32" into attribute, operator and
// value, at the first operator.
var conditionPattern = regexp.MustCompile(`^(.+?)\s*(>=|<=|>|<|=|~)\s*(.*)$`)

// parseWhere turns --where conditions into the API's attribute filters (the
// where query parameter of GET /items), as JSON, by attribute name:
//
//	Length>=32          numbers and dates: =, >, >=, <, <=
//	Length=10..47       a range, both ends included
//	Package=0603,0805   any of these texts (choices)
//	Notes~metal         text: contains (= is the whole text), ignoring case
//	Lead-free=yes       yes/no
//
// With c, the classes' attributes say what each value is; without, a value
// that looks like a number or a date is one, yes and no are yes and no, and
// the rest is text.
func parseWhere(list []string, c *class) (string, error) {
	filters := []object{}
	for _, s := range list {
		m := conditionPattern.FindStringSubmatch(s)
		if m == nil {
			return "", usagef("--where %q: expected NAME OP VALUE, e.g. \"Length>=32\"", s)
		}
		name, op, text := strings.TrimSpace(m[1]), m[2], strings.TrimSpace(m[3])
		typ := ""
		unit := ""
		if c != nil {
			found := false
			for _, scope := range []string{"item", "stock"} {
				if a, err := matchAttribute(*c, scope, name); err == nil {
					name, typ, unit, found = a.Name, a.Type, a.Unit, true
					break
				}
			}
			if !found {
				return "", usagef("--where %q: class %s has no attribute %q", s, c.Name, name)
			}
		}
		filter := object{"attribute": name, "op": op}
		value := func(text string) (any, error) {
			switch {
			case typ == "integer" || typ == "decimal":
				return parseNumber(text, unit)
			case typ == "date":
				return parseDate(text, time.Now())
			case typ == "boolean":
				if b, ok := parseYesNo(text); ok {
					return b, nil
				}
				return nil, usagef("--where %q: %s takes yes or no", s, name)
			case typ == "" && numberPattern.MatchString(text):
				if n, err := parseNumber(text, ""); err == nil {
					return n, nil
				}
			case typ == "" && (text == "yes" || text == "no"):
				b, _ := parseYesNo(text)
				return b, nil
			}
			return text, nil
		}
		low, high, isRange := strings.Cut(text, "..")
		switch {
		case op == "~":
			filter["op"], filter["value"] = "contains", text
		case isRange:
			if op != "=" {
				return "", usagef("--where %q: a range goes with =", s)
			}
			lo, err := value(low)
			if err != nil {
				return "", err
			}
			hi, err := value(high)
			if err != nil {
				return "", err
			}
			filter["op"], filter["value"] = "between", []any{lo, hi}
		case op == "=" && strings.Contains(text, ","):
			var any_ []string
			for _, t := range strings.Split(text, ",") {
				any_ = append(any_, strings.TrimSpace(t))
			}
			filter["op"], filter["value"] = "in", any_
		default:
			v, err := value(text)
			if err != nil {
				return "", err
			}
			filter["value"] = v
		}
		filters = append(filters, filter)
	}
	data, err := json.Marshal(filters)
	return string(data), err
}

const whereHelp = `an attribute condition, repeatable: "Length>=32", "Length=10..47", "Package=0603,0805", "Notes~metal", "Lead-free=yes"`

// parseAmount reads a stock amount of an item counted in unit (nil:
// pieces), which may be followed by the unit's label ("2.5 m").
func (e *env) parseAmount(input string, unit *string) (json.Number, error) {
	label := ""
	if unit != nil {
		label = *unit
	}
	return parseNumber(input, label)
}
