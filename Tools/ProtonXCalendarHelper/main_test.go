// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/ProtonMail/go-proton-api/server"
	"github.com/ProtonMail/gopenpgp/v2/crypto"
	"github.com/cheeseandcereal/proton-cal/pkg/auth"
	"github.com/cheeseandcereal/proton-cal/pkg/caltypes"
	"github.com/cheeseandcereal/proton-cal/pkg/config"
	"github.com/cheeseandcereal/proton-cal/pkg/event"
	"github.com/cheeseandcereal/proton-cal/pkg/papi"
	"github.com/cheeseandcereal/proton-cal/pkg/pgp"
	"github.com/cheeseandcereal/proton-cal/pkg/recurrence"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestClosedProtocol(t *testing.T) {
	for _, c := range []string{`{"method":"create"}`, `{"method":"login","username":"test@example.com","password":"synthetic","host":"https://example.com"}`, `{"method":"restore","password":"synthetic"}`, `{"method":"snapshot","start":1,"end":999999999,"zone":"UTC"}`, `{"method":"totp","code":"not-a-code"}`} {
		if _, err := decode([]byte(`{"schema":1,"id":1,"command":` + c + `}`)); err == nil {
			t.Fatal("accepted unsafe command")
		}
	}
	if _, err := decode([]byte(`{"schema":1,"id":1,"command":{"method":"restore"}} {}`)); err == nil {
		t.Fatal("accepted trailing JSON")
	}
}

type fakeAPI struct{ writes int }

func (*fakeAPI) Get(context.Context, string, url.Values, any) error { return nil }
func (f *fakeAPI) Put(context.Context, string, any, any) error      { f.writes++; return nil }
func (f *fakeAPI) Post(context.Context, string, any, any) error     { f.writes++; return nil }
func (f *fakeAPI) Delete(context.Context, string, any) error        { f.writes++; return nil }
func TestReadOnlyFence(t *testing.T) {
	f := &fakeAPI{}
	a := readAPI{f}
	ctx := context.Background()
	if a.Put(ctx, "/calendar/v1/cal/events/sync", nil, nil) == nil || a.Post(ctx, "/calendar/v1", nil, nil) == nil || a.Delete(ctx, "/calendar/v1/cal", nil) == nil || f.writes != 0 {
		t.Fatal("Calendar write crossed fence")
	}
	if readPath("/calendar/v1/../events") || readPath("/calendar/v1/cal/events/sync") || readPath("/calendar/v1/cal?evil/events") {
		t.Fatal("arbitrary route")
	}
	if a.Get(ctx, "https://example.com", nil, nil) == nil {
		t.Fatal("arbitrary read")
	}
}
func TestSessionStorageAndRotation(t *testing.T) {
	b := &memoryBackend{}
	config.SetBackend(b)
	defer config.SetBackend(nil)
	s, _ := config.NewSessionStore()
	if _, err := s.Load(); !errors.Is(err, config.ErrNoSession) {
		t.Fatal(err)
	}
	if err := s.UpdateTokens("uid", "access", "refresh"); err == nil {
		t.Fatal("rotation created missing session")
	}
	if err := s.Save(config.Session{UID: "synthetic-uid", AccessToken: "synthetic-access", RefreshToken: "synthetic-refresh", SaltedKeyPass: []byte("synthetic-key")}); err != nil {
		t.Fatal(err)
	}
	if err := s.UpdateTokens("synthetic-uid", "rotated-access", "rotated-refresh"); err != nil {
		t.Fatal(err)
	}
	v, err := s.Load()
	if err != nil || string(v.SaltedKeyPass) != "synthetic-key" || v.AccessToken != "rotated-access" {
		t.Fatal("key not preserved")
	}
	b.data = []byte("corrupt")
	if _, err = s.Load(); !errors.Is(err, config.ErrStorage) {
		t.Fatal("corruption reset")
	}
	if _, err = config.Dir(); err == nil {
		t.Fatal("disk config enabled")
	}
}
func TestSyntheticPGPAndProjection(t *testing.T) {
	cal, err := crypto.GenerateKey("Calendar", "calendar@example.com", "x25519", 0)
	if err != nil {
		t.Fatal(err)
	}
	calKR, _ := crypto.NewKeyRing(cal)
	addr, _ := crypto.GenerateKey("Address", "address@example.com", "x25519", 0)
	addrKR, _ := crypto.NewKeyRing(addr)
	key, data, sig, err := pgp.EncryptAndSign("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Synthetic encrypted event\r\nLOCATION:Synthetic room\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n", calKR, addrKR)
	if err != nil {
		t.Fatal(err)
	}
	raw := &caltypes.RawEvent{ID: "synthetic-event", CalendarID: "synthetic-calendar", StartTime: 1791453600, EndTime: 1791457200, SharedKeyPacket: key, SharedEvents: []caltypes.EventPart{{Type: caltypes.CardEncryptedAndSigned, Data: data, Signature: sig}}}
	ev, err := event.Decrypt(raw, calKR)
	if err != nil {
		t.Fatal(err)
	}
	listed := event.Listed{Event: ev, Occurrence: recurrence.Occurrence{Event: raw, Start: raw.StartTime, End: raw.EndTime}}
	r, err := project(listed, raw.CalendarID)
	if err != nil || r.Title != "Synthetic encrypted event" || r.Location != "Synthetic room" {
		t.Fatal("projection failed", err)
	}
	ev.DecryptFailed = true
	if _, err := project(listed, raw.CalendarID); err == nil {
		t.Fatal("exposed partial decrypt")
	}
	ev.DecryptFailed = false
	ev.CalendarID = "other"
	if _, err := project(listed, raw.CalendarID); err == nil {
		t.Fatal("wrong calendar")
	}
}
func TestAllDayAndOccurrenceIdentity(t *testing.T) {
	start := time.Date(2026, 10, 8, 0, 0, 0, 0, time.UTC).Unix()
	ev := &event.Event{EventID: "event", CalendarID: "cal", Summary: "Synthetic", AllDay: true, RRule: "FREQ=DAILY", StartTimezone: "UTC"}
	l := event.Listed{Event: ev, Occurrence: recurrence.Occurrence{Start: start, End: start + 86400}}
	a, err := project(l, "cal")
	if err != nil || a.StartDay.Day != 8 || a.EndDay.Day != 9 || !a.Recurring {
		t.Fatal("all-day projection")
	}
	l.Occurrence.Start += 86400
	l.Occurrence.End += 86400
	b, _ := project(l, "cal")
	if a.ID == b.ID {
		t.Fatal("occurrences collided")
	}
}
func TestChallengeFramingAndNoRawErrors(t *testing.T) {
	var out bytes.Buffer
	serve(strings.NewReader("{\"schema\":1,\"id\":1,\"command\":{\"method\":\"snapshot\",\"start\":1791453600,\"end\":1791536400,\"zone\":\"UTC\"}}\n"), &out, &memoryBackend{})
	var r reply
	if json.Unmarshal(bytes.TrimSpace(out.Bytes()), &r) != nil || r.Failure != "operation_failed" {
		t.Fatal("unexpected reply")
	}
	if failure(errors.New("SYNTHETIC account secret")) != "operation_failed" || strings.Contains(out.String(), "SYNTHETIC") {
		t.Fatal("raw diagnostic exposed")
	}
}
func TestStrictRecurrenceAndMalformedRows(t *testing.T) {
	start := int64(1791453600)
	for _, raw := range []*caltypes.RawEvent{nil, {ID: "e", CalendarID: "wrong", StartTime: start, EndTime: start + 3600}, {ID: "e", CalendarID: "cal", StartTime: start, EndTime: start + 3600, RRule: "INVALID"}} {
		if validateRows([]*caltypes.RawEvent{raw}, "cal") == nil {
			t.Fatal("accepted malformed row")
		}
	}
	raw := &caltypes.RawEvent{ID: "e", CalendarID: "cal", StartTime: start, EndTime: start + 1, RRule: "FREQ=SECONDLY", StartTimezone: "UTC"}
	if _, err := recurrence.ExpandOccurrencesStrict([]*caltypes.RawEvent{raw}, start, start+86400); err == nil {
		t.Fatal("silently truncated recurrence")
	}
	raw.RRule = "INVALID"
	if _, err := recurrence.ExpandOccurrencesStrict([]*caltypes.RawEvent{raw}, start, start+86400); err == nil {
		t.Fatal("silent recurrence fallback")
	}
}
func TestSyntheticSRPSignInAndKeyRestore(t *testing.T) {
	s := server.New(server.WithTLS(false))
	defer s.Close()
	_, _, err := s.CreateUser("synthetic-calendar-user", []byte("synthetic-calendar-password"))
	if err != nil {
		t.Fatal(err)
	}
	backend := &memoryBackend{}
	config.SetBackend(backend)
	defer config.SetBackend(nil)
	scanner := bufio.NewScanner(strings.NewReader(""))
	var out bytes.Buffer
	e := engine{input: scanner, output: &out, backend: backend}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if _, err := auth.Login(ctx, &prompter{e: &e, password: "synthetic-calendar-password"}, config.Config{Username: "synthetic-calendar-user", BaseURL: s.GetHostURL()}); err != nil {
		t.Fatal(err)
	}
	store, _ := config.NewSessionStore()
	saved, err := store.Load()
	if err != nil || len(saved.SaltedKeyPass) == 0 {
		t.Fatal("no unlock key persisted", err)
	}
	client, err := papi.FromSession(store, s.GetHostURL())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	unlocked, err := auth.UnlockKeys(ctx, store, client)
	if err != nil || len(unlocked.AddrKRs) == 0 {
		t.Fatal("restore failed", err)
	}
	for _, kr := range unlocked.AddrKRs {
		kr.ClearPrivateParams()
	}
	if out.Len() != 0 {
		t.Fatal("auth diagnostic escaped private helper")
	}
}
func TestPrivateChallengeUsesNextRequestIdentity(t *testing.T) {
	scanner := bufio.NewScanner(strings.NewReader("{\"schema\":1,\"id\":2,\"command\":{\"method\":\"totp\",\"code\":\"123456\"}}\n"))
	var out bytes.Buffer
	e := engine{input: scanner, output: &out, id: 1}
	p := prompter{e: &e}
	code, err := p.Prompt("2FA code")
	if err != nil || code != "123456" || e.id != 2 {
		t.Fatal("challenge framing failed", err)
	}
	if strings.Contains(out.String(), "123456") {
		t.Fatal("challenge echoed")
	}
}
