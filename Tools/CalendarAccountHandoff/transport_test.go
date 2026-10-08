// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package papi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCalendarForkAnonymousAndBounded(t *testing.T) {
	for _, body := range []string{
		`{"Code":1000,"UID":"child","UserID":"synthetic-account","AccessToken":"synthetic-access","RefreshToken":"synthetic-refresh"}`,
		`{"Code":1000,"UID":"child","UserID":"synthetic-account","AccessToken":"a"}`,
		`{"Code":9001,"UID":"child","UserID":"synthetic-account","AccessToken":"a","RefreshToken":"r"}`,
		`{"Code":1000,"UID":"child","UserID":"synthetic-account","AccessToken":"a","RefreshToken":"r","Payload":"unexpected"}`,
		strings.Repeat("x", 32769)} {
		calls := 0
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			calls++
			if r.Method != "GET" || r.URL.Path != "/auth/v4/sessions/forks/synthetic-selector" || r.Header.Get("Authorization") != "" || r.Header.Get("x-pm-uid") != "" || r.Header.Get("Cookie") != "" || r.Header.Get("x-pm-appversion") != AppVersion {
				t.Error("unsafe fork request")
			}
			w.Write([]byte(body))
		}))
		value, err := consumeCalendarFork(context.Background(), server.Client(), server.URL, "synthetic-selector")
		if (err == nil) != (strings.Contains(body, `"synthetic-refresh"`)) || calls != 1 {
			t.Error("accepted invalid fork or retried")
		}
		if err == nil && value.UserID != "synthetic-account" {
			t.Error("lost binding")
		}
		_, err = consumeCalendarFork(context.Background(), server.Client(), server.URL, "../secret")
		if err == nil || calls != 1 {
			t.Error("unsafe selector requested")
		}
		server.Close()
	}
}
