import Foundation
import Testing
@testable import ProtonXCore

@Test func productLaunchLinksOnlyChooseKnownWindows() {
    #expect(ProductRoute(url: URL(string: "protonx://mail")!) == .mail)
    #expect(ProductRoute(url: URL(string: "protonx://pass/")!) == .pass)
    for url in ["https://mail", "protonx://drive", "protonx://mail?password=SYNTHETIC", "protonx://mail#token", "protonx://user:secret@mail", "protonx://mail:443", "protonx://mail/login", "protonx:///mail"] {
        #expect(ProductRoute(url: URL(string: url)!) == nil)
    }
}

@Test func mailActionsHaveBoundedAcknowledgementAndClosedCapabilities() throws {
    for result in [NativeMailResult(queued: false, undoToken: 1), NativeMailResult(queued: true, undoToken: 0), NativeMailResult(actions: Array(repeating: .trash, count: 6))] {
        struct Packet: Encodable { let schema = 1; let id = 1; let result: NativeMailResult }
        #expect(throws: ProtonXError.invalidResponse) { try NativeMailProcess.decode(JSONEncoder().encode(Packet(result: result)), expectedID: 1) }
    }
}
