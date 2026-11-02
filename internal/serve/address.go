package serve

import (
	"net/http"
	"net/netip"
	"strings"
)

// clientAddress returns the address a request came from, for the session's
// trail and the logs: the connection's own address, or, when the connection
// comes from one of the trusted proxies, the last address in
// X-Forwarded-For that isn't a trusted proxy itself (each proxy appends the
// address it got the request from, so the entries before the last untrusted
// one may have been made up by the client). "" when it can't be told.
func clientAddress(r *http.Request, trusted []netip.Prefix) string {
	remote := remoteAddr(r.RemoteAddr)
	if !remote.IsValid() {
		return ""
	}
	if !isTrusted(remote, trusted) {
		return remote.String()
	}
	var hops []string
	for _, header := range r.Header.Values("X-Forwarded-For") {
		hops = append(hops, strings.Split(header, ",")...)
	}
	for i := len(hops) - 1; i >= 0; i-- {
		addr, err := netip.ParseAddr(strings.TrimSpace(hops[i]))
		if err != nil {
			return ""
		}
		addr = addr.Unmap()
		if !isTrusted(addr, trusted) {
			return addr.String()
		}
	}
	return remote.String()
}

// remoteAddr parses http.Request.RemoteAddr ("192.0.2.1:5000").
func remoteAddr(s string) netip.Addr {
	if ap, err := netip.ParseAddrPort(s); err == nil {
		return ap.Addr().Unmap()
	}
	if a, err := netip.ParseAddr(s); err == nil {
		return a.Unmap()
	}
	return netip.Addr{}
}

func isTrusted(addr netip.Addr, trusted []netip.Prefix) bool {
	for _, p := range trusted {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

// ParseTrustedProxies reads WTFD_TRUSTED_PROXIES: addresses and networks
// (192.0.2.1, 10.0.0.0/8, ::1), separated by commas or spaces.
func ParseTrustedProxies(s string) ([]netip.Prefix, error) {
	var list []netip.Prefix
	for _, item := range strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == ' ' }) {
		if strings.Contains(item, "/") {
			p, err := netip.ParsePrefix(item)
			if err != nil {
				return nil, err
			}
			list = append(list, p.Masked())
			continue
		}
		a, err := netip.ParseAddr(item)
		if err != nil {
			return nil, err
		}
		a = a.Unmap()
		list = append(list, netip.PrefixFrom(a, a.BitLen()))
	}
	return list, nil
}
