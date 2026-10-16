// Added by gitops-platform (see VENDORED.md): not part of upstream Online Boutique.

package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestParseFailRate(t *testing.T) {
	valid := map[string]float64{"": 0, " ": 0, "0": 0, "0.25": 0.25, " 0.5 ": 0.5, "1": 1}
	for in, want := range valid {
		got, err := parseFailRate(in)
		if err != nil || got != want {
			t.Errorf("parseFailRate(%q) = %v, %v; want %v, nil", in, got, err, want)
		}
	}
	for _, in := range []string{"-0.1", "1.5", "abc", "20%", "NaN"} {
		if _, err := parseFailRate(in); err == nil {
			t.Errorf("parseFailRate(%q) returned no error", in)
		}
	}
}

// okHandler counts the requests that reach it.
type okHandler struct{ calls int }

func (h *okHandler) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	h.calls++
	w.WriteHeader(http.StatusOK)
}

func serve(h http.Handler, path string) int {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec.Code
}

func TestFailRateHandlerOffReturnsNextUnchanged(t *testing.T) {
	next := &okHandler{}
	if h := failRateHandler(0, "/_healthz", func() float64 { return 0 }, next); h != http.Handler(next) {
		t.Fatal("rate 0 should return the next handler itself")
	}
}

func TestFailRateHandlerFailsBelowTheRate(t *testing.T) {
	next := &okHandler{}
	random := 0.0
	h := failRateHandler(0.3, "/_healthz", func() float64 { return random }, next)

	random = 0.29
	if code := serve(h, "/"); code != http.StatusInternalServerError {
		t.Errorf("random 0.29 < rate 0.3: got HTTP %d, want 500", code)
	}
	random = 0.3
	if code := serve(h, "/"); code != http.StatusOK {
		t.Errorf("random 0.3 is not below rate 0.3: got HTTP %d, want 200", code)
	}
	if next.calls != 1 {
		t.Errorf("next handler called %d times, want 1", next.calls)
	}
}

func TestFailRateHandlerNeverFailsTheHealthCheck(t *testing.T) {
	next := &okHandler{}
	h := failRateHandler(1, "/_healthz", func() float64 { return 0 }, next)
	if code := serve(h, "/_healthz"); code != http.StatusOK {
		t.Errorf("/_healthz with rate 1: got HTTP %d, want 200", code)
	}
	if code := serve(h, "/cart"); code != http.StatusInternalServerError {
		t.Errorf("/cart with rate 1: got HTTP %d, want 500", code)
	}
}

func TestNewFailRateHandlerRejectsAnInvalidValue(t *testing.T) {
	if _, _, err := newFailRateHandler("2", "/_healthz", &okHandler{}); err == nil {
		t.Error("FAIL_RATE=2 returned no error")
	}
	_, rate, err := newFailRateHandler("0.1", "/_healthz", &okHandler{})
	if err != nil || rate != 0.1 {
		t.Errorf("FAIL_RATE=0.1: got %v, %v; want 0.1, nil", rate, err)
	}
}
