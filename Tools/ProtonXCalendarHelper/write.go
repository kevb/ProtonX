// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	proton "github.com/ProtonMail/go-proton-api"
	"github.com/ProtonMail/gopenpgp/v2/crypto"
	"github.com/cheeseandcereal/proton-cal/pkg/calendar"
	"github.com/cheeseandcereal/proton-cal/pkg/caltypes"
	"github.com/cheeseandcereal/proton-cal/pkg/event"
	"github.com/cheeseandcereal/proton-cal/pkg/papi"
	"github.com/cheeseandcereal/proton-cal/pkg/pgp"
	"github.com/cheeseandcereal/proton-cal/pkg/recurrence"
)

var errConflict = errors.New("conflict")
var errUncertain = errors.New("write_uncertain")

type draft struct {
	ID         string `json:"id"`
	CalendarID string `json:"calendarID"`
	Token      string `json:"token,omitempty"`
	Title      string `json:"title"`
	Location   string `json:"location"`
	Notes      string `json:"notes"`
	Start      int64  `json:"start"`
	End        int64  `json:"end"`
	Zone       string `json:"zone"`
	AllDay     bool   `json:"allDay"`
}

func (d *draft) validate() error {
	if !identifier.MatchString(d.ID) || !identifier.MatchString(d.CalendarID) || strings.TrimSpace(d.Title) == "" || len(d.Title) > 512 || len(d.Location) > 1024 || len(d.Notes) > 16384 || utf8.RuneCountInString(d.Title) > 255 || utf8.RuneCountInString(d.Location) > 255 || utf8.RuneCountInString(d.Notes) > 3000 || strings.ContainsAny(d.Title, "\r\n\x00") || strings.ContainsRune(d.Location, 0) || strings.ContainsRune(d.Notes, 0) || d.Start < 0 || d.End <= d.Start || d.End > 2145916800 || d.End-d.Start > 366*86400 || len(d.Zone) > 128 {
		return errInput
	}
	if _, err := time.LoadLocation(d.Zone); err != nil {
		return errInput
	}
	if d.AllDay && (d.Start%86400 != 0 || d.End%86400 != 0 || d.Zone != "UTC") {
		return errInput
	}
	if d.Token != "" {
		if len(d.Token) != 64 {
			return errInput
		}
		if _, err := hex.DecodeString(d.Token); err != nil {
			return errInput
		}
	}
	return nil
}

type editScope struct{ calendarID, eventID, token string }

func fingerprint(raw *caltypes.RawEvent) string {
	if raw.NativeVersion != "" {
		return raw.NativeVersion
	}
	bytes, _ := json.Marshal(raw)
	hash := sha256.Sum256(bytes)
	return hex.EncodeToString(hash[:])
}
func editable(ev *event.Event, raw *caltypes.RawEvent) bool {
	return raw != nil && ev != nil && !ev.DecryptFailed && raw.RRule == "" && raw.RecurrenceID == 0 && len(raw.Exdates) == 0 && len(raw.Attendees) == 0 && len(raw.AttendeesEvents) == 0 && raw.AttendeesInfo.MoreAttendees == 0 && ev.Organizer == nil && ev.Conference == nil && len(ev.Attendees) == 0 && !ev.MoreAttendees && len(raw.SharedEvents) > 0
}
func (e *engine) owned(info calendar.Info) bool {
	if e.unlocked == nil || info.Type != 0 || info.Permissions&3 == 0 || info.Flags != 1 || !identifier.MatchString(info.MemberID) {
		return false
	}
	for _, addr := range e.unlocked.Addresses {
		if addr.ID == info.AddressID && strings.EqualFold(addr.Email, info.Email) && addr.Status == proton.AddressStatusEnabled && bool(addr.Send) && bool(addr.Receive) && e.unlocked.AddrKRs[addr.ID] != nil {
			return true
		}
	}
	return false
}
func (e *engine) api() papi.API {
	if e.writeAPI != nil {
		return e.writeAPI
	}
	return e.client
}

// An isolated capability grants exactly one nonempty sync event in one calendar.
// No deletion, import/overwrite, arrays of targets or other methods can escape.
type singleWriteAPI struct {
	papi.API
	calendarID, eventID, memberID string
	sent                          bool
}

func (a *singleWriteAPI) Put(ctx context.Context, path string, body, out any) error {
	if a.sent || path != "/calendar/v1/"+a.calendarID+"/events/sync" {
		return errReadOnly
	}
	bytes, err := json.Marshal(body)
	if err != nil || len(bytes) > 128*1024 {
		return errInput
	}
	var p struct {
		MemberID string
		IsImport *int
		Events   []struct {
			ID        string
			Overwrite *int
			Event     *json.RawMessage
		}
	}
	if json.Unmarshal(bytes, &p) != nil || !identifier.MatchString(p.MemberID) || p.MemberID != a.memberID || len(p.Events) != 1 || p.Events[0].Event == nil || p.Events[0].ID != a.eventID {
		return errReadOnly
	}
	if a.eventID == "" {
		if p.IsImport == nil || *p.IsImport != 0 || p.Events[0].Overwrite == nil || *p.Events[0].Overwrite != 0 {
			return errReadOnly
		}
	} else if p.IsImport != nil || p.Events[0].Overwrite != nil {
		return errReadOnly
	}
	a.sent = true
	return a.API.Put(ctx, path, body, out)
}
func (*singleWriteAPI) Post(context.Context, string, any, any) error { return errReadOnly }
func (*singleWriteAPI) Delete(context.Context, string, any) error    { return errReadOnly }
func (a *singleWriteAPI) Get(ctx context.Context, path string, q url.Values, out any) error {
	if a.eventID != "" && path == "/calendar/v1/"+a.calendarID+"/events/"+a.eventID {
		return a.API.Get(ctx, path, q, out)
	}
	return readAPI{a.API}.Get(ctx, path, q, out)
}

// Recheck membership and verify the owned calendar passphrase's detached signature
// with official Proton OpenPGP before allowing a write. Read-only shared calendars
// remain on the existing experimental reader path.
func (e *engine) writeAccess(ctx context.Context, id string) (*calendar.Access, error) {
	api := readAPI{e.api()}
	infos, err := calendar.List(ctx, api)
	if err != nil {
		return nil, err
	}
	for _, info := range infos {
		if info.ID != id {
			continue
		}
		if !e.owned(info) {
			return nil, errReadOnly
		}
		access, err := calendar.UnlockOwnedForWrite(ctx, api, e.unlocked, info)
		if err != nil {
			return nil, errReadOnly
		}
		return access, nil
	}
	return nil, errReadOnly
}
func verifyCards(raw *caltypes.RawEvent, access *calendar.Access) error {
	for _, group := range []struct {
		parts []caltypes.EventPart
		key   string
	}{{raw.SharedEvents, raw.SharedKeyPacket}, {raw.CalendarEvents, raw.CalendarKeyPacket}} {
		for _, part := range group.parts {
			if part.Type != caltypes.CardSigned && part.Type != caltypes.CardEncryptedAndSigned {
				return errReadOnly
			}
			plain := part.Data
			if part.IsEncrypted() {
				var err error
				plain, err = pgp.DecryptPart(part.Data, group.key, access.KR)
				if err != nil {
					return errReadOnly
				}
			}
			sig, err := crypto.NewPGPSignatureFromArmored(part.Signature)
			if err != nil {
				return errReadOnly
			}
			if access.AddrKR.VerifyDetached(crypto.NewPlainMessage([]byte(plain)), sig, time.Now().Unix()) != nil {
				return errReadOnly
			}
		}
	}
	return nil
}
func (e *engine) saveEvent(ctx context.Context, d *draft) (any, error) {
	if d == nil || d.validate() != nil {
		return nil, errInput
	}
	if e.api() == nil || e.keys == nil || e.unlocked == nil {
		return nil, errors.New("invalid_state")
	}
	if e.writeBlocked {
		return nil, errUncertain
	}
	if !e.collections[d.CalendarID] {
		return nil, errReadOnly
	}
	var scope editScope
	if d.Token != "" {
		var ok bool
		scope, ok = e.scope[d.ID]
		if !ok || scope.calendarID != d.CalendarID || scope.token != d.Token {
			return nil, errConflict
		}
	}
	access, err := e.writeAccess(ctx, d.CalendarID)
	if err != nil {
		return nil, err
	}
	defer access.KR.ClearPrivateParams()
	reader := &singleWriteAPI{API: e.api(), calendarID: d.CalendarID, eventID: scope.eventID}
	start, end := time.Unix(d.Start, 0), time.Unix(d.End, 0)
	var saved *caltypes.RawEvent
	writer := &singleWriteAPI{API: e.api(), calendarID: d.CalendarID, eventID: scope.eventID, memberID: access.MemberID}
	if d.Token == "" {
		// A retained editor has a stable random UID. Manual recovery after an uncertain
		// create reconciles that UID; it never creates a second copy of this draft.
		uid := "protonx-" + d.ID
		existing, err := event.GetByUID(ctx, reader, d.CalendarID, uid)
		if err != nil {
			return nil, err
		}
		if len(existing) > 0 {
			if len(existing) != 1 {
				return nil, errConflict
			}
			saved = existing[0]
		} else {
			e.writeBlocked = true
			saved, err = event.Create(ctx, writer, access, event.CreateOptions{UID: uid, Summary: d.Title, Description: d.Notes, Location: d.Location, Start: start, End: end, TZName: d.Zone, AllDay: d.AllDay})
		}
	} else {
		var current *event.Event
		raw, fetchErr := event.Get(ctx, reader, d.CalendarID, scope.eventID)
		if fetchErr != nil {
			return nil, fetchErr
		}
		if raw.ID != scope.eventID || raw.CalendarID != d.CalendarID || fingerprint(raw) != scope.token {
			return nil, errConflict
		}
		current, err = event.Decrypt(raw, access.KR)
		if err != nil || !editable(current, raw) {
			return nil, errReadOnly
		}
		if verifyCards(raw, access) != nil {
			return nil, errReadOnly
		}
		e.writeBlocked = true
		saved, err = event.NativeUpdate(ctx, writer, access, raw, current, event.UpdateOptions{Summary: &d.Title, Description: &d.Notes, Location: &d.Location, Start: &start, End: &end, TZName: d.Zone}, d.AllDay)
		if err == nil && saved == nil {
			saved, err = event.Get(ctx, reader, d.CalendarID, scope.eventID)
		}
	}
	if err != nil || saved == nil {
		if e.writeBlocked {
			return nil, errUncertain
		}
		return nil, errConflict
	}
	if validateRows([]*caltypes.RawEvent{saved}, d.CalendarID) != nil || !identifier.MatchString(saved.ID) || (d.Token != "" && saved.ID != scope.eventID) || (d.Token == "" && saved.UID != "protonx-"+d.ID) {
		e.writeBlocked = true
		return nil, errUncertain
	}
	ev, err := event.Decrypt(saved, access.KR)
	if err != nil || !editable(ev, saved) || ev.Summary != d.Title || ev.Location != d.Location || ev.Description != d.Notes || ev.Start.Unix() != d.Start || ev.End.Unix() != d.End || ev.AllDay != d.AllDay || verifyCards(saved, access) != nil {
		e.writeBlocked = true
		return nil, errUncertain
	}
	r, err := project(event.Listed{Event: ev, Occurrence: recurrence.Occurrence{Event: saved, Start: d.Start, End: d.End}}, d.CalendarID)
	if err != nil {
		return nil, errUncertain
	}
	r.WriteToken = fingerprint(saved)
	if e.scope == nil {
		e.scope = map[string]editScope{}
	}
	e.scope[r.ID] = editScope{calendarID: d.CalendarID, eventID: saved.ID, token: r.WriteToken}
	e.writeBlocked = false
	return struct {
		Phase string `json:"phase"`
		Event record `json:"event"`
	}{"connected", r}, nil
}
