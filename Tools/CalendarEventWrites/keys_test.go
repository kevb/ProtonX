// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package calendar

import (
	"context"
	"github.com/cheeseandcereal/proton-cal/pkg/pgp"
	"testing"
)

func TestNativeWriteBootstrapVerifiesExactOwnerAndSignature(t *testing.T) {
	f := newCalFixtures(t)
	sig, err := pgp.SignDetached(string(f.calPassphrase), f.addrKR)
	if err != nil {
		t.Fatal(err)
	}
	info := Info{ID: testCalendarID, MemberID: testMemberID, AddressID: testAddressID, Email: "me@example.com", Permissions: 3, Flags: 1}
	for _, bad := range []string{"", "signature", "member", "permission", "key", "inactive", "ambiguous"} {
		t.Run(bad, func(t *testing.T) {
			body := f.bootstrap()
			members := body["Members"].([]map[string]any)
			members[1]["Permissions"] = 3
			members[1]["Flags"] = 1
			pp := body["Passphrase"].(map[string]any)["MemberPassphrases"].([]map[string]any)
			pp[1]["Signature"] = sig
			switch bad {
			case "signature":
				pp[1]["Signature"] = "invalid"
			case "member":
				members[1]["AddressID"] = "other"
			case "permission":
				members[1]["Permissions"] = 112
			case "inactive":
				body["Keys"].([]map[string]any)[1]["Flags"] = 0
			case "ambiguous":
				keys := body["Keys"].([]map[string]any)
				body["Keys"] = append(keys, keys[1])
			case "key":
				body["Keys"].([]map[string]any)[1]["PrivateKey"] = f.wrongPassKeyArm
			}
			mux := newCountingMux()
			f.serveBootstrap(mux, body)
			client := newTestClient(t, mux)
			access, err := UnlockOwnedForWrite(context.Background(), client, f.unlockedAccounts, info)
			if bad == "" {
				if err != nil || access == nil {
					t.Fatal("verified owner refused", err)
				}
				access.KR.ClearPrivateParams()
			} else if err == nil {
				t.Fatal("unsafe bootstrap accepted")
			}
			if mux.hitCount(BootstrapPath(testCalendarID)) != 1 {
				t.Fatal("key material fetched twice")
			}
		})
	}
}
