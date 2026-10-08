// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package papi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"time"

	"github.com/cheeseandcereal/proton-cal/pkg/config"
)

var forkSelector = regexp.MustCompile(`^[A-Za-z0-9_=-]{1,512}$`)

type CalendarFork struct{ UID, UserID, AccessToken, RefreshToken string }

// This is an anonymous, one-use request to the fixed Proton origin, not a
// request through the parent's authenticated client. No retries or cookies.
func ConsumeCalendarFork(ctx context.Context, selector string) (CalendarFork, error) {
	client := &http.Client{Timeout: 45 * time.Second, Transport: nativeTransport(config.DefaultBaseURL),
		CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("fork redirect refused") }}
	defer client.CloseIdleConnections()
	return consumeCalendarFork(ctx, client, config.DefaultBaseURL, selector)
}
func consumeCalendarFork(ctx context.Context, client *http.Client, origin, selector string) (CalendarFork, error) {
	var out CalendarFork
	if !forkSelector.MatchString(selector) {
		return out, errors.New("invalid fork selector")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, origin+"/auth/v4/sessions/forks/"+selector, nil)
	if err != nil {
		return out, err
	}
	req.Header.Set("x-pm-appversion", AppVersion)
	req.Header.Set("User-Agent", UserAgent)
	resp, err := client.Do(req)
	if err != nil {
		return out, errors.New("fork request failed")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 32769))
	defer clear(data)
	if err != nil || len(data) > 32768 || resp.StatusCode != http.StatusOK {
		return out, errors.New("fork response refused")
	}
	var r struct {
		Code                                   int
		UID, UserID, AccessToken, RefreshToken string
		Payload                                *string
	}
	if json.Unmarshal(data, &r) != nil || r.Code != 1000 || r.UID == "" || len(r.UID) > 128 || r.UserID == "" || len(r.UserID) > 128 ||
		r.AccessToken == "" || len(r.AccessToken) > 8192 || r.RefreshToken == "" || len(r.RefreshToken) > 8192 || (r.Payload != nil && *r.Payload != "") {
		return out, errors.New("fork response refused")
	}
	return CalendarFork{r.UID, r.UserID, r.AccessToken, r.RefreshToken}, nil
}
