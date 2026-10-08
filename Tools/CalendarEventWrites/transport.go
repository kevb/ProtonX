// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package papi

import (
	"context"
	"encoding/json"
	"net/url"
)

// One dispatch only. Even 401/429 cannot replay an event write implicitly.
func (c *Client) nativeWriteOnce(ctx context.Context, method, path string, query url.Values, body, out any) error {
	sess, err := c.session()
	if err != nil {
		return err
	}
	status, response, err := c.doOnce(ctx, method, path, query, body, sess)
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 || (response.envelope.Code != CodeSuccess && response.envelope.Code != CodeSuccessMulti) {
		return &Error{Status: status, Code: response.envelope.Code}
	}
	if out != nil {
		return json.Unmarshal(response.raw, out)
	}
	return nil
}
