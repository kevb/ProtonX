// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum LockTarget: Hashable, CaseIterable, Sendable {
    case pass, mail, calendar
}

struct LockSettings: Equatable, Sendable {
    static let passAutoLockKey = "passAutoLockSeconds"
    static let legacyAutoLockKey = "autoLockSeconds"
    static let mailAutoLockKey = "mailAutoLockSeconds"
    static let lockMailOnScreenLockKey = "lockMailOnScreenLock"
    static let keepMailOpenOnWindowCloseKey = "keepMailOpenOnWindowClose"
    static let mailBackgroundSyncWhileLockedKey = "mailBackgroundSyncWhileLocked"
    static let passBackgroundCacheSyncKey = "passBackgroundCacheSync"
    static let linkMailCalendarUnlockKey = "linkMailCalendarUnlock"

    static let defaultPassAutoLockSeconds = 300
    static let defaultMailAutoLockSeconds = 86_400

    var passAutoLockSeconds: Int = defaultPassAutoLockSeconds
    var mailAutoLockSeconds: Int = defaultMailAutoLockSeconds
    var lockMailOnScreenLock: Bool = true
    var keepMailOpenOnWindowClose: Bool = true
    var mailBackgroundSyncWhileLocked: Bool = true
    var passBackgroundCacheSync: Bool = false
    var linkMailCalendarUnlock: Bool = true

    static func load(from defaults: UserDefaults = .standard) -> LockSettings {
        let passSeconds: Int
        if let explicit = defaults.object(forKey: passAutoLockKey) as? Int {
            passSeconds = max(0, explicit)
        } else if let legacy = defaults.object(forKey: legacyAutoLockKey) as? Int, legacy > 0 {
            passSeconds = legacy
        } else {
            passSeconds = defaultPassAutoLockSeconds
        }
        let mailSeconds: Int
        if let explicit = defaults.object(forKey: mailAutoLockKey) as? Int {
            mailSeconds = max(0, explicit)
        } else {
            mailSeconds = defaultMailAutoLockSeconds
        }
        return LockSettings(
            passAutoLockSeconds: passSeconds,
            mailAutoLockSeconds: mailSeconds,
            lockMailOnScreenLock: defaults.object(forKey: lockMailOnScreenLockKey) as? Bool ?? true,
            keepMailOpenOnWindowClose: defaults.object(forKey: keepMailOpenOnWindowCloseKey) as? Bool ?? true,
            mailBackgroundSyncWhileLocked: defaults.object(forKey: mailBackgroundSyncWhileLockedKey) as? Bool ?? true,
            passBackgroundCacheSync: defaults.object(forKey: passBackgroundCacheSyncKey) as? Bool ?? false,
            linkMailCalendarUnlock: defaults.object(forKey: linkMailCalendarUnlockKey) as? Bool ?? true
        )
    }

    func targetsForSystemLock(_ reason: SystemIntegration.SystemLockReason) -> Set<LockTarget> {
        var targets: Set<LockTarget> = [.pass]
        // Display dimming alone doesn't lock Mail/Calendar; screen lock, sleep and user switching do when enabled.
        if lockMailOnScreenLock && reason != .displaySleep {
            targets.insert(.mail)
            targets.insert(.calendar)
        }
        return targets
    }

    func targetsForWindowClose() -> Set<LockTarget> {
        keepMailOpenOnWindowClose ? [.pass] : Set(LockTarget.allCases)
    }
}
