// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	proton "github.com/ProtonMail/go-proton-api"
	"github.com/ProtonMail/go-proton-api/server"
	"github.com/cheeseandcereal/proton-cal/pkg/auth"
	"github.com/cheeseandcereal/proton-cal/pkg/calendar"
	"github.com/cheeseandcereal/proton-cal/pkg/config"
	"github.com/cheeseandcereal/proton-cal/pkg/papi"
	"strings"
	"testing"
	"time"
)

func syntheticHandoff() *accountHandoff {
	return &accountHandoff{Selector: "synthetic-selector", AccountID: "synthetic-account", KeyPassHex: "73796e746865746963", Expires: time.Now().Unix() + 120}
}
func TestHandoffStagesWithoutPublishingAndCommitsOwnChild(t *testing.T) {
	b := &memoryBackend{}
	calls := 0
	e := engine{backend: b, redeem: func(context.Context, string) (papi.CalendarFork, error) {
		calls++
		return papi.CalendarFork{UID: "child", UserID: "synthetic-account", AccessToken: "child-access", RefreshToken: "child-refresh"}, nil
	}, unlockHandoff: func(_ context.Context, c *engine) error {
		c.unlocked = &auth.Unlocked{User: proton.User{ID: "synthetic-account"}}
		return nil
	}}
	defer e.close()
	defer config.SetBackend(nil)
	if _, err := e.stageHandoff(context.Background(), syntheticHandoff()); err != nil {
		t.Fatal(err)
	}
	if len(b.data) != 0 || e.pending == nil || e.unlocked != nil || calls != 1 {
		t.Fatal("published before local commit")
	}
	if _, err := e.commitHandoff(context.Background()); err != nil {
		t.Fatal(err)
	}
	var saved config.Session
	if json.Unmarshal(b.data, &saved) != nil || saved.UID != "child" || saved.AccessToken != "child-access" || saved.RefreshToken != "child-refresh" || string(saved.SaltedKeyPass) != "synthetic" {
		t.Fatal("wrong child credentials")
	}
	if _, err := e.commitHandoff(context.Background()); err == nil {
		t.Fatal("replayed commit")
	}
}
func TestHandoffRefusesExpiredMismatchedAndExistingSessions(t *testing.T) {
	for _, kind := range []string{"expired", "fork-account", "unlocked-account", "existing", "storage-failure", "key-failure", "cancelled", "expired-commit", "cancelled-commit", "existing-commit"} {
		b := &memoryBackend{}
		calls := 0
		h := syntheticHandoff()
		ctx, cancel := context.WithCancel(context.Background())
		e := engine{backend: b, redeem: func(context.Context, string) (papi.CalendarFork, error) {
			calls++
			id := h.AccountID
			if kind == "fork-account" {
				id = "other"
			}
			return papi.CalendarFork{UID: "child", UserID: id, AccessToken: "a", RefreshToken: "r"}, nil
		}, unlockHandoff: func(_ context.Context, c *engine) error {
			if kind == "key-failure" {
				return errors.New("synthetic failure")
			}
			id := h.AccountID
			if kind == "unlocked-account" {
				id = "other"
			}
			c.unlocked = &auth.Unlocked{User: proton.User{ID: id}}
			return nil
		}}
		if kind == "expired" {
			h.Expires = time.Now().Unix() - 1
		}
		if kind == "existing" {
			b.data = []byte("existing credentials")
		}
		if kind == "storage-failure" {
			b.data = []byte("corrupt credentials")
		}
		if kind == "cancelled" {
			cancel()
		}
		_, err := e.stageHandoff(ctx, h)
		if kind == "expired-commit" || kind == "cancelled-commit" || kind == "existing-commit" {
			if err != nil {
				t.Fatal(kind, err)
			}
			if kind == "expired-commit" {
				e.handoffExpires = time.Now().Unix() - 1
			}
			if kind == "cancelled-commit" {
				cancel()
			}
			if kind == "existing-commit" {
				b.data = []byte("existing credentials")
			}
			_, err = e.commitHandoff(ctx)
		}
		if err == nil || e.unlocked != nil {
			t.Fatal("accepted", kind)
		}
		if kind == "existing" || kind == "existing-commit" {
			if string(b.data) != "existing credentials" {
				t.Fatal("overwrote account")
			}
		} else if kind == "storage-failure" {
			if string(b.data) != "corrupt credentials" {
				t.Fatal("reset credentials")
			}
		} else if len(b.data) != 0 {
			t.Fatal("persisted unverified account", kind)
		}
		if (kind == "expired" || kind == "existing" || kind == "storage-failure") && calls != 0 {
			t.Fatal("consumed before validation")
		}
		e.close()
		cancel()
		config.SetBackend(nil)
	}
}
func TestHandoffClosedCommandAndMixedFields(t *testing.T) {
	for _, method := range []string{"restore", "commit_handoff", "snapshot", "login"} {
		c := command{Method: method, Handoff: syntheticHandoff()}
		data, _ := json.Marshal(packet{Schema: 1, ID: 1, Command: c})
		if _, err := decode(data); err == nil {
			t.Fatal("mixed handoff", method)
		}
	}
	h := syntheticHandoff()
	h.Selector = "../escape"
	data, _ := json.Marshal(packet{Schema: 1, ID: 1, Command: command{Method: "account_handoff", Handoff: h}})
	if _, err := decode(data); err == nil {
		t.Fatal("path injection")
	}
}
func TestExistingSavedSessionRequiresLocalUnlockWithoutForkConsumption(t *testing.T) {
	b := &memoryBackend{}
	b.data, _ = json.Marshal(config.Session{UID: "existing-child", AccessToken: "synthetic-a", RefreshToken: "synthetic-r", SaltedKeyPass: []byte("synthetic-key")})
	before := string(b.data)
	called := false
	e := engine{backend: b, redeem: func(context.Context, string) (papi.CalendarFork, error) {
		called = true
		return papi.CalendarFork{}, errHandoff
	}}
	out, err := e.stageHandoff(context.Background(), syntheticHandoff())
	if err != nil || out.(result).Phase != "locked" || called || string(b.data) != before || e.unlocked != nil {
		t.Fatal("existing account replaced or opened")
	}
}

// Genuine Proton mock-server SRP/key restore with distinct parent/child tokens.
// Fork HTTP framing is tested separately; this does not emulate a live server fork.
func TestHandoffUnlocksSyntheticProtonKeysAndPreservesParentCredentials(t *testing.T) {
	s := server.New(server.WithTLS(false))
	defer s.Close()
	userID, _, err := s.CreateUser("synthetic-handoff-user", []byte("synthetic-password"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	defer config.SetBackend(nil)
	login := func(b *memoryBackend) config.Session {
		config.SetBackend(b)
		var out bytes.Buffer
		e := engine{backend: b, input: bufio.NewScanner(strings.NewReader("")), output: &out}
		if _, err := auth.Login(ctx, &prompter{e: &e, password: "synthetic-password"}, config.Config{Username: "synthetic-handoff-user", BaseURL: s.GetHostURL()}); err != nil {
			t.Fatal(err)
		}
		store, _ := config.NewSessionStore()
		value, err := store.Load()
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	parent := &memoryBackend{}
	parentSession := login(parent)
	before := string(parent.data)
	child := &memoryBackend{}
	childSession := login(child)
	if parentSession.UID == childSession.UID {
		t.Fatal("mock reused parent token")
	}
	target := &memoryBackend{}
	e := engine{backend: target, redeem: func(context.Context, string) (papi.CalendarFork, error) {
		return papi.CalendarFork{UID: childSession.UID, UserID: userID, AccessToken: childSession.AccessToken, RefreshToken: childSession.RefreshToken}, nil
	}, unlockHandoff: func(ctx context.Context, c *engine) error {
		config.SetBackend(c.backend)
		store, _ := config.NewSessionStore()
		client, err := papi.FromSession(store, s.GetHostURL())
		if err != nil {
			return err
		}
		u, err := auth.UnlockKeys(ctx, store, client)
		if err != nil {
			client.Close()
			return err
		}
		c.client = client
		c.unlocked = u
		c.keys = calendar.NewKeychain(readAPI{client}, u)
		return nil
	}}
	defer e.close()
	h := syntheticHandoff()
	h.AccountID = userID
	h.KeyPassHex = hex.EncodeToString(parentSession.SaltedKeyPass)
	if _, err := e.stageHandoff(ctx, h); err != nil {
		t.Fatal(err)
	}
	if e.pending == nil || len(e.pending.unlocked.AddrKRs) == 0 || len(target.data) != 0 {
		t.Fatal("key staging failed")
	}
	if _, err := e.commitHandoff(ctx); err != nil {
		t.Fatal(err)
	}
	var saved config.Session
	if json.Unmarshal(target.data, &saved) != nil || saved.UID != childSession.UID || saved.AccessToken == parentSession.AccessToken || string(parent.data) != before {
		t.Fatal("parent tokens copied or altered")
	}
	clear(parentSession.SaltedKeyPass)
	clear(childSession.SaltedKeyPass)
	parent.Delete()
	child.Delete()
}
