// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ProtonXApp

@Suite struct ProductionInstanceTests {
    @Test func launchFromBackupYieldsToOlderInstalledProcessEvenWhenPidsWrap() {
        let old = ProductionInstance.Candidate(pid: 78790, launched: Date(timeIntervalSince1970: 100))
        let new = ProductionInstance.Candidate(pid: 16268, launched: Date(timeIntervalSince1970: 200))
        #expect(ProductionInstance.primary(current: new, others: [old]) == old.pid)
        #expect(ProductionInstance.primary(current: old, others: [new]) == old.pid)
    }
    @Test func simultaneousLaunchesPickSameProcessInEitherOrder() {
        let a = ProductionInstance.Candidate(pid: 100, launched: Date(timeIntervalSince1970: 100))
        let b = ProductionInstance.Candidate(pid: 101, launched: a.launched)
        let c = ProductionInstance.Candidate(pid: 102, launched: a.launched)
        #expect(ProductionInstance.primary(current: a, others: [c, b]) == a.pid)
        #expect(ProductionInstance.primary(current: b, others: [c, a]) == a.pid)
        #expect(ProductionInstance.primary(current: c, others: [b, a]) == a.pid)
    }
    @Test func missingDatesHaveDeterministicFallbackAndSoloLaunchOwnsProcess() {
        let a = ProductionInstance.Candidate(pid: 100, launched: nil)
        let b = ProductionInstance.Candidate(pid: 101, launched: nil)
        #expect(ProductionInstance.primary(current: a, others: []) == a.pid)
        #expect(ProductionInstance.primary(current: a, others: [b]) == a.pid)
        #expect(ProductionInstance.primary(current: b, others: [a]) == a.pid)
    }
}
