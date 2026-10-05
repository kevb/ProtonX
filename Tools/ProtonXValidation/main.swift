import AppKit
import Foundation
import ProtonXCore

private struct TestCredential: Codable, Sendable {
    let username: String
    let password: String
}

@MainActor
private final class SetupDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ProtonXValidation.configure()
        NSApplication.shared.terminate(nil)
    }
}

@main
struct ProtonXValidation {
    private static let account = "overnight-validation"
    private static let keychain = KeychainStore(service: "org.kevb.ProtonX.Testing")

    @MainActor private static var setupDelegate: SetupDelegate?
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--probe" {
            do { print(try keychain.load(account: account) == nil ? "not-configured" : "ready") }
            catch { print("keychain-unavailable") }
            return
        }
        if arguments.first == "--clear" {
            do { try keychain.delete(account: account); print("Temporary test password removed") }
            catch { print("Keychain cleanup failed") }
            return
        }
        if ["--validate", "--validate-session"].contains(arguments.first ?? ""), arguments.count == 3 {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                let passed = await validate(helper: URL(fileURLWithPath: arguments[1]), profile: URL(fileURLWithPath: arguments[2]), signIn: arguments.first == "--validate")
                exit(passed ? 0 : 1)
            }
            app.run()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        setupDelegate = SetupDelegate()
        app.delegate = setupDelegate
        app.run()
    }

    @MainActor fileprivate static func configure() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = "ProtonX overnight test account"
        alert.informativeText = "Store only your designated test account here. Credentials stay in this Mac’s local Keychain and are used for ProtonX sign-in and synthetic vault checks. The tool removes its stored password after validation finishes. It does not send mail."
        let username = NSTextField(frame: NSRect(x: 0, y: 100, width: 420, height: 24))
        username.placeholderString = "Test account username"
        username.setAccessibilityLabel("Test account username")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 55, width: 420, height: 24))
        password.placeholderString = "Test account password"
        password.setAccessibilityLabel("Test account password")
        let note = NSTextField(labelWithString: "The encrypted ProtonX session may remain for native UI checks.\nOne clearly named synthetic note is left in Trash after CRUD checks.")
        note.frame = NSRect(x: 0, y: 0, width: 420, height: 40)
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 130))
        fields.addSubview(username); fields.addSubview(password); fields.addSubview(note)
        alert.accessoryView = fields
        alert.addButton(withTitle: "Save for overnight validation")
        alert.addButton(withTitle: "Cancel")
        alert.window.title = "ProtonX Test Account"
        alert.window.initialFirstResponder = username
        app.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !username.stringValue.isEmpty, !password.stringValue.isEmpty else {
            let error = NSAlert(); error.messageText = "Both fields are required"; error.runModal(); return
        }
        do {
            let credential = TestCredential(username: username.stringValue, password: password.stringValue)
            try keychain.save(JSONEncoder().encode(credential), account: account)
            password.stringValue = ""; username.stringValue = ""
        } catch {
            password.stringValue = ""
            let alert = NSAlert(); alert.messageText = "Could not save test credentials"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }

    private static func validate(helper: URL, profile: URL, signIn: Bool) async -> Bool {
        var stage = "Keychain access"
        // Erase the temporary password on every completed attempt, including errors.
        defer {
            if signIn {
                do { try keychain.delete(account: account); print("Temporary test password removed from local Keychain") }
                catch { print("Temporary test password cleanup failed; remove org.kevb.ProtonX.Testing in Keychain Access.") }
            }
        }
        do {
            let service = PassService(runner: NativeProcess(executable: helper, directory: profile))
            if signIn {
                guard let data = try keychain.load(account: account) else { throw ProtonXError.invalidInput("No test credential is configured.") }
                let credential = try JSONDecoder().decode(TestCredential.self, from: data)
                stage = "native direct sign-in"
                try await service.login { challenge in
                    switch challenge.title {
                    case "Proton username": return credential.username
                    case "Proton password": return credential.password
                    default: throw ProtonXError.invalidInput("This sign-in requires an additional verification method. Enter it interactively in ProtonX.")
                    }
                }
                print("Native direct sign-in: passed")
            }
            stage = "desktop capabilities"
            _ = try await service.capabilities()
            print("Desktop account capabilities: passed")
            stage = "vault metadata"
            let vaults = try await service.vaults()
            guard let vault = vaults.first else { throw ProtonXError.invalidInput("No vault is available.") }
            _ = try await service.items(in: vault)
            print("Vault and item metadata: passed")
            let title = "ProtonX validation " + UUID().uuidString
            let body = "Synthetic developer validation only. Safe to delete."
            stage = "synthetic note creation"
            try await service.createNote(title: title, note: body, vault: vault)
            let items = try await service.items(in: vault)
            guard let item = items.first(where: { $0.title == title }) else { throw ProtonXError.invalidResponse }
            stage = "synthetic note read"
            let detail = try await service.detail(item)
            guard detail.title == title, detail.note == body else { throw ProtonXError.invalidResponse }
            stage = "synthetic note edit"
            let updated = body + "\nUpdated through private stdin."
            try await service.update(item, fields: ["note": updated])
            guard try await service.detail(item).note == updated else { throw ProtonXError.invalidResponse }
            stage = "synthetic trash and restore"
            try await service.trash(item)
            guard try await service.items(in: vault, trashed: true).contains(where: { $0.id == item.id }) else { throw ProtonXError.invalidResponse }
            try await service.trash(item, restore: true)
            guard try await service.items(in: vault).contains(where: { $0.id == item.id }) else { throw ProtonXError.invalidResponse }
            try await service.trash(item)
            print("Synthetic create/read/edit/trash/restore: passed; synthetic note left in Trash")
            return true
        } catch {
            // Only adapter-sanitized failures and static fixture-stage names are printed.
            print("Validation failed during \(stage): \(error.localizedDescription)")
            return false
        }
    }
}
