// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package papi

import (
	"context"
	"github.com/cheeseandcereal/proton-cal/pkg/config"
	"io"
	"net/http"
	"strings"
	"testing"
)

type writeTransport struct {
	hits   int
	status int
}

func (t *writeTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	t.hits++
	return &http.Response{StatusCode: t.status, Body: io.NopCloser(strings.NewReader(`{"Code":2000}`)), Header: make(http.Header), Request: r}, nil
}
func TestCalendarWritesNeverRetryAfter401Or429(t *testing.T) {
	for _, status := range []int{401, 429, 500} {
		tr := &writeTransport{status: status}
		c := &Client{baseURL: config.DefaultBaseURL, httpc: &http.Client{Transport: tr}, sess: config.Session{UID: "synthetic", AccessToken: "synthetic", RefreshToken: "synthetic"}}
		if c.Put(context.Background(), "/calendar/v1/cal/events/sync", map[string]any{}, nil) == nil || tr.hits != 1 {
			t.Fatal("write retried or accepted failure")
		}
	}
}
