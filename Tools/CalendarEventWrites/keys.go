// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
package calendar

import (
	"context"
	"errors"
	"github.com/ProtonMail/gopenpgp/v2/crypto"
	"github.com/cheeseandcereal/proton-cal/pkg/auth"
	"github.com/cheeseandcereal/proton-cal/pkg/papi"
	"github.com/cheeseandcereal/proton-cal/pkg/pgp"
	"strings"
	"time"
)

// A write uses fresh, verified key material from exactly one bootstrap. It
// cannot fall back to another member's passphrase or the reader's lenient cache.
func UnlockOwnedForWrite(ctx context.Context, api papi.API, unlocked *auth.Unlocked, info Info) (*Access, error) {
	denied := errors.New("unverified calendar ownership")
	if unlocked == nil || info.Type != 0 || info.Permissions&3 == 0 || info.Flags != 1 {
		return nil, denied
	}
	var boot bootstrapResponse
	if err := api.Get(ctx, BootstrapPath(info.ID), nil, &boot); err != nil {
		return nil, err
	}
	matched := false
	for _, m := range boot.Members {
		if m.ID == info.MemberID && m.AddressID == info.AddressID && strings.EqualFold(m.Email, info.Email) && m.Permissions&3 != 0 && m.Flags == 1 {
			matched = true
		}
	}
	kr := unlocked.AddrKRs[info.AddressID]
	if !matched || kr == nil {
		return nil, denied
	}
	for _, mp := range boot.Passphrase.MemberPassphrases {
		if mp.MemberID != info.MemberID {
			continue
		}
		plain, err := pgp.DecryptArmored(mp.Passphrase, kr)
		if err != nil {
			return nil, denied
		}
		defer clear(plain)
		sig, err := crypto.NewPGPSignatureFromArmored(mp.Signature)
		if err != nil || kr.VerifyDetached(crypto.NewPlainMessage(plain), sig, time.Now().Unix()) != nil {
			return nil, denied
		}
		primary := []calendarKey{}
		for _, key := range boot.Keys {
			if key.CalendarID == info.ID && key.Flags&3 == 3 {
				primary = append(primary, key)
			}
		}
		if len(primary) != 1 {
			return nil, denied
		}
		calKR, err := unlockCalendarKeys(info.ID, primary, plain)
		if err != nil {
			return nil, denied
		}
		signer, err := unlocked.PrimaryAddrKR(info.AddressID)
		if err != nil {
			calKR.ClearPrivateParams()
			return nil, denied
		}
		return &Access{CalendarID: info.ID, KR: calKR, MemberID: info.MemberID, AddressID: info.AddressID, AddrKR: signer, Settings: boot.Settings}, nil
	}
	return nil, denied
}
