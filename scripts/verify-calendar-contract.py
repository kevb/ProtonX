#!/usr/bin/env python3
"""Check the pinned Calendar build inputs and closed native protocol."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
protocol = json.loads((root / "Resources/CalendarProtocol.json").read_text())
pin = next(
    s
    for s in json.loads((root / "upstream.lock.json").read_text())["sources"]
    if s["name"] == "proton-cal"
)
assert protocol == {
    "schema": 1,
    "appVersion": "Other",
    "userAgent": "ProtonX-Calendar/0.1",
    "apiHost": "https://mail-api.proton.me",
    "source": pin["revision"],
    "maxRequestBytes": 65536,
    "maxResponseBytes": 8388608,
    "maxCalendars": 64,
    "maxEvents": 5000,
    "maxRangeDays": 62,
}
source = root / ".tools/calendar-native"
assert (source / "go.mod").read_bytes() == (
    root / "Resources/CalendarHelper.mod"
).read_bytes()
assert (source / "go.sum").read_bytes() == (
    root / "Resources/CalendarHelper.sum"
).read_bytes()
config = (source / "pkg/config/config.go").read_text()
assert (
    "org.kevb.ProtonX.Calendar.Native"
    in (root / "Tools/ProtonXCalendarHelper/keychain_darwin.go").read_text()
)
assert "https://mail-api.proton.me" in config and 'return "", ErrStorage' in config
api = (source / "pkg/papi/papi.go").read_text()
assert 'UserAgent = "ProtonX-Calendar/0.1"' in api and 'AppVersion = "Other"' in api
assert (
    "t.Proxy=nil" in api
    and "Calendar redirect refused" in api
    and "c.storageErr=config.ErrStorage" in api
)
assert "ExpandOccurrencesStrict" in (source / "pkg/event/decrypt.go").read_text()
assert "pkg/browser" not in (source / "pkg/auth/auth.go").read_text()
print(
    "Calendar source pin, protocol, storage, transport and strict recurrence contracts match"
)
