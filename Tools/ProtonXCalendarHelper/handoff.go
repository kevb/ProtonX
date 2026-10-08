// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/cheeseandcereal/proton-cal/pkg/config"
	"github.com/cheeseandcereal/proton-cal/pkg/papi"
	"regexp"
	"time"
)

var errHandoff = errors.New("handoff_unavailable")
var handoffSelector = regexp.MustCompile(`^[A-Za-z0-9_=-]{1,512}$`)

type accountHandoff struct {
	Selector   string `json:"selector"`
	AccountID  string `json:"accountID"`
	KeyPassHex string `json:"keyPassHex"`
	Expires    int64  `json:"expires"`
}

func (h *accountHandoff) valid(now int64) bool {
	if h == nil || !handoffSelector.MatchString(h.Selector) || !identifier.MatchString(h.AccountID) || h.Expires <= now || h.Expires > now+120 || len(h.KeyPassHex) == 0 || len(h.KeyPassHex) > 8192 || len(h.KeyPassHex)%2 != 0 {
		return false
	}
	for _, b := range []byte(h.KeyPassHex) {
		if !(b >= '0' && b <= '9' || b >= 'a' && b <= 'f') {
			return false
		}
	}
	return true
}

// Stage and unlock in memory. Only the subsequent, locally authorized commit
// publishes a Calendar session. Existing Calendar credentials are never replaced.
func (e *engine) stageHandoff(ctx context.Context, h *accountHandoff) (any, error) {
	if !h.valid(time.Now().Unix()) || ctx.Err() != nil || e.client != nil || e.pending != nil {
		return nil, errHandoff
	}
	data, err := e.backend.Read()
	if err == nil {
		var saved config.Session
		valid := len(data) <= 32768 && json.Unmarshal(data, &saved) == nil && saved.Valid() && len(saved.SaltedKeyPass) > 0
		clear(data)
		clear(saved.SaltedKeyPass)
		if valid {
			return result{Phase: "locked"}, nil
		}
		return nil, config.ErrStorage
	}
	clear(data)
	if !errors.Is(err, config.ErrNoSession) {
		return nil, err
	}
	redeem := e.redeem
	if redeem == nil {
		redeem = papi.ConsumeCalendarFork
	}
	fork, err := redeem(ctx, h.Selector)
	if err != nil || fork.UserID != h.AccountID {
		return nil, errHandoff
	}
	key, err := hex.DecodeString(h.KeyPassHex)
	if err != nil {
		return nil, errHandoff
	}
	defer clear(key)
	staging := &memoryBackend{}
	b, err := json.Marshal(config.Session{UID: fork.UID, AccessToken: fork.AccessToken, RefreshToken: fork.RefreshToken, SaltedKeyPass: key})
	if err != nil {
		return nil, errHandoff
	}
	staging.Write(b)
	clear(b)
	candidate := &engine{backend: staging}
	defer config.SetBackend(e.backend)
	unlock := e.unlockHandoff
	if unlock == nil {
		unlock = func(ctx context.Context, c *engine) error { return c.restore(ctx) }
	}
	if err = unlock(ctx, candidate); err != nil {
		candidate.close()
		staging.Delete()
		return nil, errHandoff
	}
	if candidate.unlocked == nil || candidate.unlocked.User.ID != h.AccountID || ctx.Err() != nil || !h.valid(time.Now().Unix()) {
		candidate.close()
		staging.Delete()
		return nil, errHandoff
	}
	e.pending = candidate
	e.handoffExpires = h.Expires
	return result{Phase: "handoff_ready"}, nil
}
func (e *engine) commitHandoff(ctx context.Context) (any, error) {
	if e.pending == nil || time.Now().Unix() >= e.handoffExpires || ctx.Err() != nil {
		e.clearHandoff()
		return nil, errHandoff
	}
	old, err := e.backend.Read()
	clear(old)
	if !errors.Is(err, config.ErrNoSession) {
		e.clearHandoff()
		return nil, errHandoff
	}
	staging := e.pending.backend.(*memoryBackend)
	data, err := staging.Read()
	if err != nil {
		e.clearHandoff()
		return nil, errHandoff
	}
	defer clear(data)
	if err = e.backend.Write(data); err != nil {
		e.clearHandoff()
		return nil, err
	}
	e.client = e.pending.client
	e.unlocked = e.pending.unlocked
	e.keys = e.pending.keys
	e.pending.client = nil
	e.pending.unlocked = nil
	e.pending.keys = nil
	staging.Delete()
	e.pending = nil
	e.handoffExpires = 0
	config.SetBackend(e.backend)
	return result{Phase: "connected"}, nil
}
func (e *engine) clearHandoff() {
	if e.pending != nil {
		e.pending.close()
		e.pending.backend.(*memoryBackend).Delete()
		e.pending = nil
	}
	e.handoffExpires = 0
}
