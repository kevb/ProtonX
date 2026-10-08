// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"context"
	"encoding/json"
	"errors"
	proton "github.com/ProtonMail/go-proton-api"
	"github.com/ProtonMail/gopenpgp/v2/crypto"
	"github.com/cheeseandcereal/proton-cal/pkg/auth"
	"github.com/cheeseandcereal/proton-cal/pkg/calendar"
	"github.com/cheeseandcereal/proton-cal/pkg/caltypes"
	"github.com/cheeseandcereal/proton-cal/pkg/ical"
	"github.com/cheeseandcereal/proton-cal/pkg/pgp"
	"net/url"
	"strings"
	"testing"
)

type eventWriteFixture struct {
	boot        any
	row         *caltypes.RawEvent
	writes      int
	loseReply   bool
	permissions int
	updateTime  int
}

func jsonAssign(out, value any) error {
	b, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, out)
}
func (f *eventWriteFixture) wire() map[string]any {
	if f.row == nil {
		return nil
	}
	b, _ := json.Marshal(f.row)
	var m map[string]any
	json.Unmarshal(b, &m)
	m["UpdateTime"] = f.updateTime
	return m
}
func (f *eventWriteFixture) Get(_ context.Context, path string, q url.Values, out any) error {
	switch path {
	case "/calendar/v1":
		return jsonAssign(out, map[string]any{"Calendars": []any{map[string]any{"ID": "cal", "Type": 0, "Members": []any{map[string]any{"ID": "member", "AddressID": "addr", "Email": "synthetic@example.com", "Name": "Synthetic calendar", "Permissions": f.permissions, "Flags": 1}}}}})
	case "/calendar/v2/cal/bootstrap":
		return jsonAssign(out, f.boot)
	case "/calendar/v1/cal/events":
		rows := []any{}
		if f.row != nil && f.row.UID == q.Get("UID") {
			rows = append(rows, f.wire())
		}
		return jsonAssign(out, map[string]any{"Events": rows})
	case "/calendar/v1/cal/events/event":
		return jsonAssign(out, map[string]any{"Event": f.wire()})
	}
	return errReadOnly
}
func (f *eventWriteFixture) Put(_ context.Context, path string, payload, out any) error {
	if path != "/calendar/v1/cal/events/sync" {
		return errReadOnly
	}
	f.writes++
	var p struct {
		MemberID string
		Events   []struct {
			ID    string
			Event struct {
				SharedKeyPacket, CalendarKeyPacket       string
				SharedEventContent, CalendarEventContent []caltypes.EventPart
				Color                                    string
				Notifications                            []caltypes.Notification
			}
		}
	}
	if jsonAssign(&p, payload) != nil || len(p.Events) != 1 || p.MemberID != "member" {
		return errInput
	}
	b := p.Events[0].Event
	if f.row == nil {
		f.row = &caltypes.RawEvent{ID: "event", CalendarID: "cal", SharedKeyPacket: b.SharedKeyPacket, CalendarKeyPacket: b.CalendarKeyPacket}
	}
	f.row.SharedEvents = b.SharedEventContent
	f.row.CalendarEvents = b.CalendarEventContent
	for _, part := range b.SharedEventContent {
		if part.Type == caltypes.CardSigned {
			v, err := ical.ParseFragment(part.Data)
			if err != nil || v.Start == nil || v.End == nil {
				return errInput
			}
			f.row.UID = v.UID
			f.row.StartTime = v.Start.Unix()
			f.row.EndTime = v.End.Unix()
			f.row.StartTimezone = v.TZName
			f.row.EndTimezone = v.TZName
			f.row.FullDay = 0
			if strings.Contains(part.Data, "DTSTART;VALUE=DATE:") {
				f.row.FullDay = 1
			}
		}
	}
	f.row.Color = b.Color
	f.row.Notifications = b.Notifications
	f.row.NotificationsSet = len(b.Notifications) > 0
	f.updateTime++
	if f.loseReply {
		return errors.New("synthetic transport interrupted")
	}
	return jsonAssign(out, map[string]any{"Code": 1001, "Responses": []any{map[string]any{"Index": 0, "Response": map[string]any{"Code": 1000, "Event": f.wire()}}}})
}
func (*eventWriteFixture) Post(context.Context, string, any, any) error { return errReadOnly }
func (*eventWriteFixture) Delete(context.Context, string, any) error    { return errReadOnly }
func writeFixture(t *testing.T) (*engine, *eventWriteFixture, *draft) {
	t.Helper()
	addr, err := crypto.GenerateKey("Synthetic address", "synthetic@example.com", "x25519", 0)
	if err != nil {
		t.Fatal(err)
	}
	addrKR, _ := crypto.NewKeyRing(addr)
	key, _ := crypto.GenerateKey("Synthetic calendar", "calendar@example.com", "x25519", 0)
	pass := []byte("synthetic-passphrase")
	locked, _ := key.Lock(pass)
	armor, _ := locked.Armor()
	cipher, _ := addrKR.Encrypt(crypto.NewPlainMessage(pass), nil)
	enc, _ := cipher.GetArmored()
	sig, _ := pgp.SignDetached(string(pass), addrKR)
	f := &eventWriteFixture{permissions: 3, boot: map[string]any{"Members": []any{map[string]any{"ID": "member", "AddressID": "addr", "Email": "synthetic@example.com", "Permissions": 3, "Flags": 1}}, "Keys": []any{map[string]any{"ID": "key", "CalendarID": "cal", "PrivateKey": armor, "Flags": 3}}, "Passphrase": map[string]any{"MemberPassphrases": []any{map[string]any{"MemberID": "member", "Passphrase": enc, "Signature": sig}}}}}
	u := &auth.Unlocked{Addresses: []proton.Address{{ID: "addr", Email: "synthetic@example.com", Status: proton.AddressStatusEnabled, Send: true, Receive: true}}, AddrKRs: map[string]*crypto.KeyRing{"addr": addrKR}}
	e := &engine{writeAPI: f, unlocked: u, keys: calendar.NewKeychain(f, u), collections: map[string]bool{"cal": true}, scope: map[string]editScope{}}
	return e, f, &draft{ID: "synthetic-draft", CalendarID: "cal", Title: "Synthetic event", Location: "Synthetic room", Notes: "Synthetic notes\nSecond line", Start: 1791453600, End: 1791457200, Zone: "UTC"}
}
func savedRecord(t *testing.T, v any) record {
	t.Helper()
	var result struct{ Event record }
	if jsonAssign(&result, v) != nil {
		t.Fatal("invalid projection")
	}
	return result.Event
}
func TestNativeCreateEditEncryptAndTouchExactlyOneEvent(t *testing.T) {
	e, f, d := writeFixture(t)
	ctx := context.Background()
	v, err := e.saveEvent(ctx, d)
	if err != nil {
		t.Fatal("create", err)
	}
	r := savedRecord(t, v)
	if r.Title != d.Title || r.WriteToken == "" || f.writes != 1 {
		t.Fatal("unconfirmed create")
	}
	for _, p := range f.row.SharedEvents {
		if strings.Contains(p.Data, d.Title) || strings.Contains(p.Data, d.Location) {
			t.Fatal("plaintext event text")
		}
	}
	f.row.Color = "#123456"
	f.row.Notifications = []caltypes.Notification{{Type: 1, Trigger: "-PT15M"}}
	f.row.NotificationsSet = true
	// Simulate refresh to establish a current row capability.
	var fresh caltypes.RawEvent
	jsonAssign(&fresh, f.wire())
	token := fingerprint(&fresh)
	e.scope[r.ID] = editScope{"cal", "event", token}
	d.ID = r.ID
	d.Token = token
	d.Title = "Synthetic revised event"
	d.Start = 1791417600
	d.End = 1791504000
	d.AllDay = true
	v, err = e.saveEvent(ctx, d)
	if err != nil {
		t.Fatal("edit", err)
	}
	r = savedRecord(t, v)
	if f.writes != 2 || r.Title != d.Title || !r.AllDay || f.row.ID != "event" || f.row.UID != "protonx-synthetic-draft" || f.row.Color != "#123456" || len(f.row.Notifications) != 1 {
		t.Fatal("edit lost identity/metadata")
	}
}
func TestNativeWritesRefuseStaleRowsAndRecurringBeforeDispatch(t *testing.T) {
	e, f, d := writeFixture(t)
	v, err := e.saveEvent(context.Background(), d)
	if err != nil {
		t.Fatal(err)
	}
	r := savedRecord(t, v)
	d.ID = r.ID
	d.Token = r.WriteToken
	f.updateTime++
	if _, err = e.saveEvent(context.Background(), d); !errors.Is(err, errConflict) || f.writes != 1 {
		t.Fatal("stale version wrote")
	}
	var fresh caltypes.RawEvent
	jsonAssign(&fresh, f.wire())
	d.Token = fingerprint(&fresh)
	e.scope[r.ID] = editScope{"cal", "event", d.Token}
	f.row.RRule = "FREQ=DAILY"
	jsonAssign(&fresh, f.wire())
	d.Token = fingerprint(&fresh)
	e.scope[r.ID] = editScope{"cal", "event", d.Token}
	if _, err = e.saveEvent(context.Background(), d); !errors.Is(err, errReadOnly) || f.writes != 1 {
		t.Fatal("recurring event wrote")
	}
}
func TestNativeUncertainCreateCannotReplayAndReconcilesStableUID(t *testing.T) {
	e, f, d := writeFixture(t)
	f.loseReply = true
	if _, err := e.saveEvent(context.Background(), d); !errors.Is(err, errUncertain) || f.writes != 1 {
		t.Fatal("lost response not uncertain")
	}
	if _, err := e.saveEvent(context.Background(), d); !errors.Is(err, errUncertain) || f.writes != 1 {
		t.Fatal("uncertain save retried")
	}
	// Successful snapshot clears the operation block; manually resubmitting the
	// retained draft then finds the exact UID rather than creating a second row.
	e.writeBlocked = false
	f.loseReply = false
	if _, err := e.saveEvent(context.Background(), d); err != nil || f.writes != 1 {
		t.Fatal("recovery duplicated create", err)
	}
}
func TestNativeWritesRejectRevokedOwnershipAndTamperedCards(t *testing.T) {
	e, f, d := writeFixture(t)
	f.permissions = 112
	if _, err := e.saveEvent(context.Background(), d); !errors.Is(err, errReadOnly) || f.writes != 0 {
		t.Fatal("unowned calendar wrote")
	}
	f.permissions = 3
	v, err := e.saveEvent(context.Background(), d)
	if err != nil {
		t.Fatal(err)
	}
	r := savedRecord(t, v)
	f.row.SharedEvents[0].Signature = "tampered"
	var fresh caltypes.RawEvent
	jsonAssign(&fresh, f.wire())
	d.ID = r.ID
	d.Token = fingerprint(&fresh)
	e.scope[r.ID] = editScope{"cal", "event", d.Token}
	if _, err := e.saveEvent(context.Background(), d); !errors.Is(err, errReadOnly) || f.writes != 1 {
		t.Fatal("unsigned edit wrote")
	}
}
func TestSingleEventFenceForbidsDeleteBatchOverwriteAndOtherRoutes(t *testing.T) {
	ctx := context.Background()
	f := &fakeAPI{}
	for _, p := range []string{`{"MemberID":"other","Events":[{"ID":"event","Event":{}}]}`, `{"MemberID":"member","Events":[{"ID":"event"}]}`, `{"MemberID":"member","Events":[{"ID":"event","Event":{}},{"ID":"other","Event":{}}]}`, `{"MemberID":"member","Events":[{"ID":"other","Event":{}}]}`, `{"MemberID":"member","Events":[{"ID":"event","Overwrite":1,"Event":{}}]}`} {
		a := &singleWriteAPI{API: f, calendarID: "cal", eventID: "event", memberID: "member"}
		var body any
		json.Unmarshal([]byte(p), &body)
		if a.Put(ctx, "/calendar/v1/cal/events/sync", body, nil) == nil {
			t.Fatal("unsafe write crossed fence")
		}
	}
	if f.writes != 0 {
		t.Fatal("unsafe dispatch")
	}
	a := &singleWriteAPI{API: f, calendarID: "cal", eventID: "event", memberID: "member"}
	body := map[string]any{"MemberID": "member", "Events": []any{map[string]any{"ID": "event", "Event": map[string]any{}}}}
	if a.Put(ctx, "/calendar/v1/cal/events/sync", body, nil) != nil || a.Put(ctx, "/calendar/v1/cal/events/sync", body, nil) == nil || f.writes != 1 {
		t.Fatal("one-shot fence failed")
	}
	if a.Get(ctx, "/calendar/v1/cal/events/other", nil, nil) == nil {
		t.Fatal("arbitrary event read")
	}
}
