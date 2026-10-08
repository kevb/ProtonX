// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package event

import (
	"context"
	"encoding/json"
	"github.com/cheeseandcereal/proton-cal/pkg/caltypes"
	"github.com/cheeseandcereal/proton-cal/pkg/pgp"
	"strings"
	"testing"
	"time"
)

func TestNativeUpdateOneEventPreservesCardsRemindersAndColour(t *testing.T) {
	raw := fabricateRaw(t, "ev1", "uid1", 1781506800, 1781508600, "Europe/Berlin", "", 0, nil, "Old title", 2, fixtureExtras{status: "TENTATIVE", transp: "TRANSPARENT", created: "20260601T000000Z", comment: "Private comment"})
	raw.NotificationsSet = true
	raw.Notifications = []caltypes.Notification{{Type: 1, Trigger: "-PT15M"}}
	raw.Color = "#123456"
	access := testAccess(t)
	current, err := Decrypt(raw, access.KR)
	if err != nil {
		t.Fatal(err)
	}
	rec := newSyncRecorder()
	client := newTestClient(t, rec)
	title, notes, location := "Synthetic changed title", "Synthetic notes\nSecond line", "Synthetic room"
	start, end := time.Date(2026, 10, 8, 0, 0, 0, 0, time.UTC), time.Date(2026, 10, 9, 0, 0, 0, 0, time.UTC)
	_, err = NativeUpdate(context.Background(), client, access, raw, current, UpdateOptions{Summary: &title, Description: &notes, Location: &location, Start: &start, End: &end, TZName: "UTC"}, true)
	if err != nil {
		t.Fatal(err)
	}
	bodies := rec.bodies()
	if len(bodies) != 1 {
		t.Fatal("multiple writes")
	}
	entries := bodies[0]["Events"].([]any)
	if len(entries) != 1 || entries[0].(map[string]any)["ID"] != "ev1" {
		t.Fatal("wrong event scope")
	}
	body := entries[0].(map[string]any)["Event"].(map[string]any)
	if body["Color"] != "#123456" || len(body["Notifications"].([]any)) != 1 {
		t.Fatal("lost colour/reminders")
	}
	bytes, _ := json.Marshal(body)
	if strings.Contains(string(bytes), title) || strings.Contains(string(bytes), location) {
		t.Fatal("private fields in plaintext")
	}
	parts := body["SharedEventContent"].([]any)
	signed := parts[0].(map[string]any)["Data"].(string)
	if !strings.Contains(signed, "DTSTART;VALUE=DATE:20261008") || !strings.Contains(signed, "DTEND;VALUE=DATE:20261009") {
		t.Fatal("all-day conversion failed")
	}
	plain, err := pgp.DecryptPart(parts[1].(map[string]any)["Data"].(string), raw.SharedKeyPacket, access.KR)
	if err != nil || !strings.Contains(plain, "SUMMARY:"+title) || !strings.Contains(plain, "CREATED:20260601T000000Z") {
		t.Fatal("lost encrypted fields")
	}
	cal := body["CalendarEventContent"].([]any)
	if !strings.Contains(cal[0].(map[string]any)["Data"].(string), "TRANSP:TRANSPARENT") || !strings.Contains(cal[0].(map[string]any)["Data"].(string), "STATUS:TENTATIVE") {
		t.Fatal("lost unrelated calendar properties")
	}
}
