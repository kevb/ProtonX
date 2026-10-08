// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package event

import (
	"context"
	"github.com/cheeseandcereal/proton-cal/pkg/calendar"
	"github.com/cheeseandcereal/proton-cal/pkg/caltypes"
	"github.com/cheeseandcereal/proton-cal/pkg/papi"
)

// Operates on the one row already fetched and checked by the native adapter.
// Patches/reseals the pinned cards; preserves untouched iCal properties,
// reminders and colour. No recurrence orchestration or exception deletion.
func NativeUpdate(ctx context.Context, client papi.API, access *calendar.Access, raw *caltypes.RawEvent, current *Event, opts UpdateOptions, allDay bool) (*caltypes.RawEvent, error) {
	copy := *current
	copy.AllDay = allDay
	body, err := buildUpdateBody(raw, &copy, opts, access)
	if err != nil {
		return nil, err
	}
	resp, err := putSync(ctx, client, access.CalendarID, syncReq{MemberID: access.MemberID, Events: []syncEventReq{{ID: raw.ID, Event: body}}})
	if err != nil {
		return nil, err
	}
	return resp.firstEvent()
}
