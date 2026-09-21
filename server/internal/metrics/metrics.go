// Package metrics exposes a minimal Prometheus text-format endpoint without
// pulling in the Prometheus client library.
package metrics

import (
	"fmt"
	"net/http"

	sig "crosstransfer/server/internal/signal"
	"crosstransfer/server/internal/turn"
)

// Handler renders hub and TURN counters in Prometheus exposition format.
func Handler(hub *sig.Hub, t *turn.Server) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		st := hub.Stats()
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		gauge := func(name, help string, v any) {
			fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s gauge\n%s %v\n", name, help, name, name, v)
		}
		counter := func(name, help string, v any) {
			fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s counter\n%s %v\n", name, help, name, name, v)
		}
		gauge("ct_peers", "Connected signaling peers.", st.Peers)
		gauge("ct_shares", "Active shares (take-codes).", st.Shares)
		gauge("ct_sessions", "Active sessions.", st.Sessions)
		gauge("ct_turn_allocations", "Embedded TURN allocations.", t.AllocationCount())
		counter("ct_claims_ok_total", "Successful claims.", st.ClaimsOK)
		counter("ct_claims_failed_total", "Failed claims.", st.ClaimsFailed)
		counter("ct_claims_rate_limited_total", "Rate-limited claims.", st.ClaimsLimited)
		counter("ct_signal_forwards_total", "Forwarded signal messages.", st.SignalForwards)
		counter("ct_relay_frames_total", "Forwarded relay frames.", st.RelayFrames)
		counter("ct_relay_bytes_total", "Forwarded relay bytes.", st.RelayBytes)
		counter("ct_relay_dropped_total", "Relay frames dropped by rate limit.", st.RelayDropped)
	})
}
