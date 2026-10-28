package cli

import (
	"encoding/json"
	"fmt"
	"math/big"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// numberPattern splits "12.5mm", "-3 °C" or "1e3" into number and unit.
var numberPattern = regexp.MustCompile(`^\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)\s*(.*?)\s*$`)

// splitMeasure returns the number and the (possibly empty) unit of input.
func splitMeasure(input string) (*big.Rat, string, error) {
	m := numberPattern.FindStringSubmatch(input)
	if m == nil {
		return nil, "", fmt.Errorf("%q is not a number", input)
	}
	r, ok := new(big.Rat).SetString(m[1])
	if !ok {
		return nil, "", fmt.Errorf("%q is not a number", input)
	}
	return r, m[2], nil
}

// symbolAliases spell unit symbols that are hard to type.
var symbolAliases = strings.NewReplacer(
	"μ", "µ", // Greek mu → micro sign
	"Ω", "Ω", // ohm sign → Greek omega
	"ohm", "Ω", "Ohm", "Ω", "OHM", "Ω",
	"deg", "°",
)

// matchUnit finds a unit by symbol or name: exactly, then with ASCII
// spellings ("um", "kohm", "degC"), then ignoring case if that is unique.
// Units that convert the same count as one, such as the B of decimal and of
// binary bytes; the first of them is returned.
func matchUnit(units []unit, s string) (*unit, error) {
	s = strings.TrimSpace(s)
	candidates := []string{s, symbolAliases.Replace(s)}
	if strings.HasPrefix(s, "u") && len(s) > 1 {
		candidates = append(candidates, "µ"+symbolAliases.Replace(s[1:]))
	}
	for _, c := range candidates {
		for i := range units {
			if units[i].Symbol == c {
				return &units[i], nil
			}
		}
	}
	var folded []*unit
	for i := range units {
		for _, c := range candidates {
			if strings.EqualFold(units[i].Symbol, c) || strings.EqualFold(units[i].Name, c) {
				folded = append(folded, &units[i])
				break
			}
		}
	}
	if len(folded) == 0 {
		return nil, fmt.Errorf("unknown unit %q", s)
	}
	for _, u := range folded[1:] {
		if !sameConversion(u, folded[0]) {
			var names []string
			for _, u := range folded {
				names = append(names, u.Symbol+" ("+u.Name+")")
			}
			return nil, ambiguous("unit", s, names)
		}
	}
	return folded[0], nil
}

func sameConversion(a, b *unit) bool {
	return a.BaseFactor == b.BaseFactor && a.BaseOffset == b.BaseOffset
}

// unitsOf returns the units of a quantity, by family and size.
func (e *env) unitsOf(quantityID string) ([]unit, error) {
	if e.cache.units == nil {
		e.cache.units = map[string][]unit{}
	}
	if us, ok := e.cache.units[quantityID]; ok {
		return us, nil
	}
	var us []unit
	if err := e.get("/units", map[string][]string{"quantity": {quantityID}}, &us); err != nil {
		return nil, err
	}
	e.cache.units[quantityID] = us
	return us, nil
}

// familyUnits returns the units of u's family, smallest first.
func (e *env) familyUnits(u *unit) ([]unit, error) {
	all, err := e.unitsOf(u.Quantity.ID)
	if err != nil {
		return nil, err
	}
	var us []unit
	for _, v := range all {
		if v.Family.ID == u.Family.ID {
			us = append(us, v)
		}
	}
	return us, nil
}

// parseMeasure converts input such as "12mm" to the base unit of u's
// quantity, where u is the unit of an attribute or item. A plain number is
// in u. Any unit of the quantity is accepted; a symbol is looked up in u's
// family first. With u nil (pieces) only plain numbers are accepted.
func (e *env) parseMeasure(input string, u *unit) (json.Number, error) {
	r, symbol, err := splitMeasure(input)
	if err != nil {
		return "", err
	}
	if u == nil {
		if symbol != "" {
			return "", fmt.Errorf("%q: no unit expected here", input)
		}
		return ratNumber(r), nil
	}
	q := u.Quantity
	if symbol != "" {
		family, err := e.familyUnits(u)
		if err != nil {
			return "", err
		}
		units, err := e.unitsOf(q.ID)
		if err != nil {
			return "", err
		}
		if u, err = matchUnit(family, symbol); err != nil {
			if u, err = matchUnit(units, symbol); err != nil {
				return "", fmt.Errorf("%w; %s is measured in %s", err, q.Name, unitSymbols(units))
			}
		}
	}
	factor, ok1 := new(big.Rat).SetString(u.BaseFactor.String())
	offset, ok2 := new(big.Rat).SetString(u.BaseOffset.String())
	if !ok1 || !ok2 {
		return "", fmt.Errorf("unit %s has no usable factor", u.Symbol)
	}
	r.Mul(r, factor).Add(r, offset)
	if q.Datatype == "integer" && !r.IsInt() {
		return "", fmt.Errorf("%q: %s must be a whole number", input, q.Name)
	}
	return ratNumber(r), nil
}

// unitSymbols lists the symbols of units, each once.
func unitSymbols(units []unit) string {
	var s []string
	seen := map[string]bool{}
	for _, u := range units {
		if !seen[u.Symbol] {
			s = append(s, u.Symbol)
			seen[u.Symbol] = true
		}
	}
	return strings.Join(s, ", ")
}

// ratNumber formats r as a decimal: exact when possible, else to 30 places.
func ratNumber(r *big.Rat) json.Number {
	if r.IsInt() {
		return json.Number(r.Num().String())
	}
	s := r.FloatString(30)
	s = strings.TrimRight(s, "0")
	s = strings.TrimSuffix(s, ".")
	return json.Number(s)
}

// parseValue converts command-line text to the JSON value the API expects
// for an attribute of the given datatype.
func (e *env) parseValue(a *attribute, input string) (any, error) {
	input = strings.TrimSpace(input)
	switch a.Datatype {
	case "integer", "float":
		n, err := e.parseMeasure(input, a.Unit)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", a.Name, err)
		}
		if a.Datatype == "integer" && strings.ContainsAny(n.String(), ".eE") {
			return nil, fmt.Errorf("%s: %q is not a whole number", a.Name, input)
		}
		return n, nil
	case "boolean":
		if b, ok := parseYesNo(input); ok {
			return b, nil
		}
		return nil, fmt.Errorf("%s: %q is not yes or no", a.Name, input)
	case "date":
		d, err := parseDate(input, time.Now())
		if err != nil {
			return nil, fmt.Errorf("%s: %w", a.Name, err)
		}
		return d, nil
	}
	// text, url and choice (by option name or id) go as they are.
	return input, nil
}

// parseYesNo reads yes/no, true/false, y/n, 1/0 and on/off.
func parseYesNo(input string) (bool, bool) {
	switch strings.ToLower(strings.TrimSpace(input)) {
	case "true", "yes", "y", "1", "on":
		return true, true
	case "false", "no", "n", "0", "off":
		return false, true
	}
	return false, false
}

// parseQuantity parses a stock quantity for an item with the given unit
// (nil: pieces).
func (e *env) parseQuantity(input string, u *unit) (json.Number, error) {
	return e.parseMeasure(input, u)
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
