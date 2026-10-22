// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Independent bundle paths share production profiles. Pick the same earliest
/// process even when two copies are launching together; previews stay separate.
struct ProductionInstance {
    struct Candidate {
        let pid: pid_t
        let launched: Date?
    }
    static func primary(current: Candidate, others: [Candidate]) -> pid_t {
        ([current] + others).min {
            let a = $0.launched ?? .distantFuture, b = $1.launched ?? .distantFuture
            return a == b ? $0.pid < $1.pid : a < b
        }!.pid
    }
    @MainActor static func existingPrimary() -> NSRunningApplication? {
        guard Bundle.main.bundleIdentifier == "org.kevb.ProtonX" else { return nil }
        let current = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "org.kevb.ProtonX")
            .filter { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }
        let selected = primary(current: Candidate(pid: current.processIdentifier, launched: current.launchDate),
                               others: others.map { Candidate(pid: $0.processIdentifier, launched: $0.launchDate) })
        return others.first { $0.processIdentifier == selected }
    }
}
