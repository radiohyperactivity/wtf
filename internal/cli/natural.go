package cli

import (
	"slices"
	"strings"
)

// naturalCompare orders names as the server's util.natural_key does: numbers
// inside them by their value, the rest ignoring case, so "DIP4" comes before
// "dip8" and "DIP10". Names that differ only in case keep a fixed order.
func naturalCompare(a, b string) int {
	if c := strings.Compare(naturalKey(a), naturalKey(b)); c != 0 {
		return c
	}
	return strings.Compare(a, b)
}

// naturalKey is util.natural_key: runs of digits padded to 20 places, the
// rest in lower case.
func naturalKey(s string) string {
	var b strings.Builder
	for len(s) > 0 {
		digits := s[0] >= '0' && s[0] <= '9'
		i := 1
		for i < len(s) && (s[i] >= '0' && s[i] <= '9') == digits {
			i++
		}
		if digits {
			b.WriteString(strings.Repeat("0", max(0, 20-i)))
			b.WriteString(s[:i])
		} else {
			b.WriteString(strings.ToLower(s[:i]))
		}
		s = s[i:]
	}
	return b.String()
}

// sortNatural sorts names in natural order.
func sortNatural(names []string) { slices.SortFunc(names, naturalCompare) }
