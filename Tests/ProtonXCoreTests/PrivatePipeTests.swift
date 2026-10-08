// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing
@testable import ProtonXCore

@Suite struct PrivatePipeTests {
    @Test func exitedReaderThrowsWithoutChangingOtherDescriptors() throws {
        let prepared = Pipe(), unrelated = Pipe()
        defer {
            try? prepared.fileHandleForWriting.close()
            try? unrelated.fileHandleForReading.close()
            try? unrelated.fileHandleForWriting.close()
        }
        try PrivatePipe.prepareWriting(prepared.fileHandleForWriting)
        #expect(fcntl(prepared.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE) == 1)
        #expect(fcntl(unrelated.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE) == 0)
        try prepared.fileHandleForReading.close()
        #expect(throws: Error.self) { try prepared.fileHandleForWriting.write(contentsOf: Data("synthetic".utf8)) }
    }
}
