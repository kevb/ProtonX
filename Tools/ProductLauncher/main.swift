// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor final class LauncherDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let product = Bundle.main.object(forInfoDictionaryKey: "ProtonXProduct") as? String,
              ["mail", "pass"].contains(product) else { finish("This ProtonX launcher is invalid."); return }
        let target = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ProtonX.app")
        guard Bundle(url: target)?.bundleIdentifier == "org.kevb.ProtonX" else {
            finish("Install ProtonX.app alongside this launcher in Applications."); return
        }
        // Do not route to an older development copy with the same identity.
        let otherCopy = NSRunningApplication.runningApplications(withBundleIdentifier: "org.kevb.ProtonX")
            .contains { $0.bundleURL?.standardizedFileURL != target.standardizedFileURL }
        guard !otherCopy else { finish("Quit the other ProtonX copy first, then open this launcher again."); return }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        NSWorkspace.shared.open([URL(string: "protonx://" + product)!], withApplicationAt: target, configuration: options) { _, error in
            let failed = error != nil
            Task { @MainActor in self.finish(failed ? "ProtonX could not open. Try opening ProtonX.app directly." : nil) }
        }
    }
    private func finish(_ message: String?) {
        if let message {
            let alert = NSAlert(); alert.messageText = "ProtonX"; alert.informativeText = message
            alert.addButton(withTitle: "OK"); alert.runModal()
        }
        NSApp.terminate(nil)
    }
}
@main struct ProductLauncher {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = LauncherDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
