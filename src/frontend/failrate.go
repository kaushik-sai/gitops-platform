// Added by gitops-platform (see VENDORED.md): not part of upstream Online Boutique.

package main

import (
	"fmt"
	"math/rand/v2"
	"net/http"
	"strconv"
	"strings"
)

// parseFailRate reads FAIL_RATE: the share of requests to fail, from 0 (off) to 1 (all).
// Empty means 0.
func parseFailRate(value string) (float64, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0, nil
	}
	rate, err := strconv.ParseFloat(value, 64)
	// Written as !(in range) so that NaN is rejected too.
	if err != nil || !(rate >= 0 && rate <= 1) {
		return 0, fmt.Errorf("FAIL_RATE must be a number from 0 to 1, got %q", value)
	}
	return rate, nil
}

// failRateHandler answers a share of requests with HTTP 500 instead of passing them on.
// It is the bad release for the canary drill. healthPath is never failed, so the
// readiness and liveness probes keep passing and only the users see the errors.
// random returns a number in [0, 1); tests pass a fixed one.
func failRateHandler(rate float64, healthPath string, random func() float64, next http.Handler) http.Handler {
	if rate <= 0 {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != healthPath && random() < rate {
			http.Error(w, "injected failure (FAIL_RATE)", http.StatusInternalServerError)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// newFailRateHandler wraps next with the rate from FAIL_RATE. An invalid value stops
// the frontend at start-up rather than running with a rate nobody asked for.
func newFailRateHandler(value, healthPath string, next http.Handler) (http.Handler, float64, error) {
	rate, err := parseFailRate(value)
	if err != nil {
		return nil, 0, err
	}
	return failRateHandler(rate, healthPath, rand.Float64, next), rate, nil
}
