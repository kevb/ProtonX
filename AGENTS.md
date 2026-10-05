# ProtonX contributor guidance

Use SwiftUI/AppKit for UI and existing Proton implementations for cryptography.
Read SECURITY.md before authentication, storage, helper or clipboard changes.
Preserve server product limits and CLI eligibility in the CLI product policy.
The native desktop helper follows its pinned desktop protocol. Keep product sessions separate; share OS integration only. Tests and screenshots
must use synthetic data. Preserve copyright/license notices and source pinning.
Never log raw helper output or put secrets in command arguments/environment.
Run the relevant contract tests and build before claiming a feature works.
