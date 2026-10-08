// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

enum PrivatePipe {
    /// An exited helper must fail its request rather than terminate the app with SIGPIPE.
    /// Scope this to the private descriptor; do not change the process's signal policy.
    static func prepareWriting(_ handle: FileHandle) throws {
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
