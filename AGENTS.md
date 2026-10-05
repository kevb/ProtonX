# ProtonX contributor guidance

Use SwiftUI/AppKit for UI and existing Proton implementations for cryptography.
Read SECURITY.md before authentication, storage, helper or clipboard changes.
Keep product sessions separate; share OS integration only. Tests and screenshots
must use synthetic data. Preserve copyright/license notices and source pinning.
Never log raw helper output or put secrets in command arguments/environment.
Run the relevant contract tests and build before claiming a feature works.
