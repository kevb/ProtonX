// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package papi

import (
	"context"
	"github.com/cheeseandcereal/proton-cal/pkg/config"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNativeTransportRefusesProxyOtherOriginAndRedirect(t *testing.T) {
	hits := 0
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("Location", "https://example.com")
		w.WriteHeader(302)
	}))
	defer s.Close()
	c := &http.Client{Transport: nativeTransport(s.URL)}
	if _, err := c.Get(s.URL); err == nil || hits != 1 {
		t.Fatal("redirect accepted")
	}
	if _, err := c.Get("https://example.com"); err == nil || hits != 1 {
		t.Fatal("different origin accepted")
	}
	tr := nativeTransport(s.URL).(calendarTransport)
	if tr.base.Proxy != nil {
		t.Fatal("inherited proxy")
	}
}

type fixtureBodyTransport string

func (body fixtureBodyTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(body))), Header: make(http.Header), Request: r}, nil
}
func TestNativeAPICodeCannotMasqueradeAsEmptyCalendar(t *testing.T) {
	for _, body := range []string{`{"Code":2000,"Error":"synthetic error"}`, `{"Calendars":[]}`} {
		// The production origin is simulated entirely in memory: no network request.
		c := &Client{baseURL: config.DefaultBaseURL, httpc: &http.Client{Transport: fixtureBodyTransport(body)}, sess: config.Session{UID: "synthetic", AccessToken: "synthetic", RefreshToken: "synthetic"}}
		var out struct{ Calendars []any }
		err := c.Get(context.Background(), "/calendar/v1", nil, &out)
		if err == nil {
			t.Fatal("invalid success envelope appeared empty")
		}
	}
}
