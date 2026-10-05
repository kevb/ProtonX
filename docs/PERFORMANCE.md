# Performance and measurement

ProtonX avoids a permanently resident Chromium/Node runtime. The main executable
is SwiftUI/AppKit; the Pass helper runs on demand. This is an architectural
property, not proof of a fixed percentage reduction in total memory.

## Local development snapshot, 2026-10-05

Apple Silicon, macOS 26.6.2, release/ad-hoc signed build. After exploring synthetic
Pass and Mail windows, and allowing the process to settle:

| Process set | Snapshot RSS | Interpretation |
| --- | ---: | --- |
| ProtonX, two product windows with synthetic data | 94.0 MiB | One app process, no idle Pass helper; sampled CPU 0.0% |
| Existing official Pass app plus its three Electron helpers | 115.4 MiB | Read-only observation of already-running processes; state/workload unverified |

The app's sampled physical footprint was 52.3 MiB (peak 76.3 MiB). RSS was higher
immediately after UI work and screenshot capture (135.9 MiB). RSS includes shared
mappings and fluctuates under memory pressure. Footprint and RSS are different
metrics; do not compare the main Electron process alone with the entire suite.

These are **unmatched snapshots**, not a controlled benchmark or a validated
18% saving. No account data was opened in the official app. No official Mail,
Bridge, or Drive workloads were measured. Real connected Pass sync can add a
transient helper; Mail adds Bridge's existing runtime. Screenshot/inspection
activity can alter the working set.

## Reproducible comparison protocol

Use disposable accounts with the same item/message counts. Include every helper
and Bridge process. Measure launch, warm idle, a vault search, selected-item
opening, sync, mail reading, send, and a long background idle period. Record
per-process RSS, physical footprint, aggregate CPU/time, wakeups, and energy via
Activity Monitor/Instruments. Repeat warm/cold runs; report medians and ranges,
architecture, OS, build mode, account size and exact revisions.

`scripts/measure-resources.sh` reports matching runtime processes without reading
process argument strings or account data. It excludes compiler/cargo processes
whose checkout paths contain the project name. Its aggregate is an inspection
aid; when both apps are running, split the rows into each product set.

No daemon or automatic sync polling is added in 0.1. The inactivity lock timer
checks every five seconds. There is no automatic login item. Closing a window
keeps the single suite process available; use Quit for zero ProtonX runtime.
