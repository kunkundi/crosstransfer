package turn

import (
	"net"
	"net/netip"
)

// The embedded relay binds udp4. Keep special-purpose destinations out even
// when a private-network operator opts into RFC1918/loopback/CGNAT peers.
// Source: https://www.iana.org/assignments/iana-ipv4-special-registry/
var deniedPeerRanges = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("169.254.0.0/16"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("192.88.99.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("224.0.0.0/4"),
	netip.MustParsePrefix("240.0.0.0/4"),
}

var sharedPeerRange = netip.MustParsePrefix("100.64.0.0/10")

func PeerAllowed(peer net.IP, allowPrivate bool) bool {
	ip, ok := netip.AddrFromSlice(peer)
	if !ok {
		return false
	}
	ip = ip.Unmap()
	if !ip.Is4() {
		return false
	}
	for _, prefix := range deniedPeerRanges {
		if prefix.Contains(ip) {
			return false
		}
	}
	if ip.IsPrivate() || ip.IsLoopback() || sharedPeerRange.Contains(ip) {
		return allowPrivate
	}
	return ip.IsGlobalUnicast()
}
